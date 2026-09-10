defmodule CymphonyElixir.Agent.ClaudeAdapterTest do
  use ExUnit.Case, async: true

  alias CymphonyElixir.Agent.Claude

  defp spec(overrides \\ %{}) do
    Map.merge(
      %{
        kind: "claude",
        command: nil,
        model: nil,
        effort: nil,
        provider: nil,
        session_id: nil,
        prompt: "do the thing",
        workspace: "/tmp/ws",
        mcp_descriptor: nil,
        settings: %{
          command: "claude",
          permission_mode: "acceptEdits",
          allowed_tools: "Bash,Read,Edit",
          output_format: "json",
          fallback_model: nil,
          max_turns: nil,
          max_budget_usd: nil,
          bare_mode: true,
          provider: nil,
          providers: []
        }
      },
      overrides
    )
  end

  describe "build_command/1" do
    test "base command carries bare/-p/prompt/output-format/permission-mode/allowedTools" do
      assert {:ok, cmd} = Claude.build_command(spec())
      assert cmd =~ "claude --bare -p 'do the thing'"
      assert cmd =~ "--output-format 'json'"
      assert cmd =~ "--permission-mode 'acceptEdits'"
      assert cmd =~ "--allowedTools 'Bash,Read,Edit'"
      refute cmd =~ "--model"
      refute cmd =~ "--effort"
      refute cmd =~ "--resume"
    end

    test "model and effort come from the run_spec, not settings" do
      assert {:ok, cmd} = Claude.build_command(spec(%{model: "opus", effort: "xhigh"}))
      assert cmd =~ "--model 'opus'"
      assert cmd =~ "--effort 'xhigh'"
    end

    test "stream-json adds --verbose; resume adds --resume" do
      settings = %{spec().settings | output_format: "stream-json"}
      assert {:ok, cmd} = Claude.build_command(spec(%{settings: settings, session_id: "sess-1"}))
      assert cmd =~ "--verbose"
      assert cmd =~ "--resume 'sess-1'"
    end

    test "command override from run_spec wins over settings" do
      assert {:ok, cmd} = Claude.build_command(spec(%{command: "cm"}))
      assert String.starts_with?(cmd, "cm ")
    end

    test "prompt is shell-escaped so metacharacters stay inside one argument" do
      assert {:ok, cmd} = Claude.build_command(spec(%{prompt: "it's; rm -rf /"}))
      assert cmd =~ ~s(-p 'it'"'"'s; rm -rf /')
    end
  end

  describe "parse_output/3 json" do
    test "reads the last JSON object line" do
      lines = [
        "noise",
        ~s({"result":"done","session_id":"s1","usage":{"input_tokens":3,"output_tokens":2}})
      ]

      assert {:ok, %{session_id: "s1", result: "done", usage: %{"input_tokens" => 3}}} =
               Claude.parse_output(lines, spec(), fn _ -> :ok end)
    end

    test "no JSON line is an error" do
      assert {:error, {:no_json_output, _}} = Claude.parse_output(["nope"], spec(), fn _ -> :ok end)
    end
  end

  describe "parse_output/3 stream-json" do
    test "emits stream events and returns the last result event" do
      settings = %{spec().settings | output_format: "stream-json"}
      me = self()

      lines = [
        ~s({"type":"system","subtype":"init"}),
        ~s({"type":"result","result":"ok","session_id":"s2","usage":{"input_tokens":5,"output_tokens":1}})
      ]

      assert {:ok, %{session_id: "s2", result: "ok"}} =
               Claude.parse_output(lines, spec(%{settings: settings}), fn msg -> send(me, {:msg, msg}) end)

      assert_received {:msg, %{event: :stream_event}}
      assert_received {:msg, %{event: :stream_event}}
    end

    test "stream with no result event is an error" do
      settings = %{spec().settings | output_format: "stream-json"}

      assert {:error, {:no_result_in_stream, _}} =
               Claude.parse_output([~s({"type":"system"})], spec(%{settings: settings}), fn _ -> :ok end)
    end
  end

  describe "build_command/1 extra_args" do
    test "a settings list is escaped and appended after the modelled flags" do
      settings = Map.put(spec().settings, :extra_args, ["--add-dir", "/srv/shared repo"])
      assert {:ok, cmd} = Claude.build_command(spec(%{settings: settings}))
      assert String.ends_with?(cmd, "'--add-dir' '/srv/shared repo'")
    end

    test "a settings string is appended raw; a missing key adds nothing" do
      settings = Map.put(spec().settings, :extra_args, "--debug --foo=1")
      assert {:ok, with_string} = Claude.build_command(spec(%{settings: settings}))
      assert String.ends_with?(with_string, "--debug --foo=1")

      assert {:ok, without} = Claude.build_command(spec())
      refute without =~ "--debug"
    end
  end

  describe "build_command/1 edge branches" do
    test "empty/nil settings.command falls back to the default binary" do
      settings = %{spec().settings | command: nil}
      assert {:ok, cmd} = Claude.build_command(spec(%{settings: settings}))
      assert String.starts_with?(cmd, "claude ")
    end

    test "nil boolean flag and empty-string session id add nothing" do
      settings = %{spec().settings | bare_mode: nil}
      assert {:ok, cmd} = Claude.build_command(spec(%{settings: settings, session_id: ""}))
      refute cmd =~ "--bare"
      refute cmd =~ "--resume"
    end

    test "integer and decimal flag values render via their clauses" do
      settings = %{spec().settings | max_turns: 5, max_budget_usd: Decimal.new("2.50")}
      assert {:ok, cmd} = Claude.build_command(spec(%{settings: settings}))
      assert cmd =~ "--max-turns 5"
      assert cmd =~ "--max-budget-usd 2.5"
    end

    test "an unwritable mcp descriptor is skipped without failing the command" do
      assert {:ok, cmd} = Claude.build_command(spec(%{mcp_descriptor: %{api_key: ""}}))
      refute cmd =~ "--mcp-config"
    end
  end

  describe "parse_output/3 edge branches" do
    test "a braces line that is not valid JSON is a decode error" do
      assert {:error, {:json_decode_failed, _, _}} =
               Claude.parse_output(["{not json}"], spec(), fn _ -> :ok end)
    end

    test "non-binary lines are skipped by the json-line scan" do
      lines = [123, ~s({"result":"ok","session_id":"s9","usage":null})]

      assert {:ok, %{session_id: "s9"}} = Claude.parse_output(lines, spec(), fn _ -> :ok end)

      assert {:error, {:no_json_output, _}} = Claude.parse_output([123, :atom], spec(), fn _ -> :ok end)
    end

    test "stream-json ignores non-JSON lines between events" do
      settings = %{spec().settings | output_format: "stream-json"}

      lines = [
        "plain log noise",
        ~s({"type":"result","result":"ok","session_id":"s3","usage":{}})
      ]

      assert {:ok, %{session_id: "s3"}} =
               Claude.parse_output(lines, spec(%{settings: settings}), fn _ -> :ok end)
    end
  end

  test "auth env callbacks" do
    assert Claude.default_command() == "claude"
    assert Claude.auth_env_prefixes() == ["ANTHROPIC_", "API_TIMEOUT", "CLAUDE_CODE_"]
    assert Claude.auth_env_fallback() == ["ANTHROPIC_API_KEY", "CLAUDE_CODE_OAUTH_TOKEN"]
  end
end
