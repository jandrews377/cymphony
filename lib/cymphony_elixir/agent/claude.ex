defmodule CymphonyElixir.Agent.Claude do
  @moduledoc """
  Claude Code CLI adapter: builds `claude -p …` commands and parses its
  `json` / `stream-json` output into the normalized turn result.
  """

  @behaviour CymphonyElixir.Agent

  alias CymphonyElixir.Mcp.ConfigWriter

  @impl true
  def default_command, do: "claude"

  @impl true
  def auth_env_prefixes, do: ["ANTHROPIC_", "API_TIMEOUT", "CLAUDE_CODE_"]

  # Inherited from the daemon's own environment when no provider supplies auth.
  # `CLAUDE_CODE_OAUTH_TOKEN` is how a Claude Code *account* (rather than an API
  # key) authenticates without a mounted `~/.claude` — the shape a container or
  # CI runner needs.
  @impl true
  def auth_env_fallback, do: ["ANTHROPIC_API_KEY", "CLAUDE_CODE_OAUTH_TOKEN"]

  @impl true
  def build_command(%{settings: settings} = run_spec) do
    args =
      []
      |> maybe_add_flag(settings.bare_mode, "--bare")
      |> maybe_add_flag(true, "-p")
      |> then(fn args -> args ++ [shell_escape(run_spec.prompt)] end)
      |> maybe_add_flag(settings.output_format, "--output-format", settings.output_format)
      |> maybe_add_flag(settings.output_format == "stream-json", "--verbose")
      |> maybe_add_flag(settings.permission_mode, "--permission-mode", settings.permission_mode)
      |> maybe_add_flag(settings.allowed_tools, "--allowedTools", settings.allowed_tools)
      |> maybe_add_flag(run_spec.model, "--model", run_spec.model)
      |> maybe_add_flag(run_spec.effort, "--effort", run_spec.effort)
      |> maybe_add_flag(settings.fallback_model, "--fallback-model", settings.fallback_model)
      |> maybe_add_flag(settings.max_turns, "--max-turns", settings.max_turns)
      |> maybe_add_flag(settings.max_budget_usd, "--max-budget-usd", settings.max_budget_usd)
      |> maybe_add_mcp_config(run_spec)
      |> maybe_add_resume_flag(run_spec.session_id)
      |> maybe_add_extra_args(Map.get(settings, :extra_args))

    command =
      case run_spec.command || settings.command do
        cmd when is_binary(cmd) and cmd != "" -> cmd
        _ -> default_command()
      end

    {:ok, Enum.join([command | args], " ")}
  end

  @impl true
  def parse_output(lines, %{settings: settings}, on_message) do
    case settings.output_format do
      "stream-json" -> parse_stream_json_output(lines, on_message)
      _ -> parse_json_output(lines)
    end
  end

  defp maybe_add_flag(args, nil, _flag), do: args
  defp maybe_add_flag(args, false, _flag), do: args
  defp maybe_add_flag(args, true, flag), do: args ++ [flag]

  defp maybe_add_flag(args, value, flag, value) when is_binary(value) and value != "",
    do: args ++ [flag, shell_escape(value)]

  defp maybe_add_flag(args, value, flag, value) when is_integer(value), do: args ++ [flag, to_string(value)]
  defp maybe_add_flag(args, %Decimal{} = value, flag, _display), do: args ++ [flag, to_string(Decimal.to_string(value))]
  defp maybe_add_flag(args, _value, _flag, _display), do: args

  defp maybe_add_resume_flag(args, nil), do: args
  defp maybe_add_resume_flag(args, ""), do: args

  defp maybe_add_resume_flag(args, session_id) when is_binary(session_id),
    do: args ++ ["--resume", shell_escape(session_id)]

  # Claude receives MCP servers as a JSON descriptor file (written 0600 inside
  # the workspace so the API key never appears in argv).
  defp maybe_add_mcp_config(args, %{mcp_descriptor: %{} = descriptor, workspace: workspace})
       when is_binary(workspace) do
    case ConfigWriter.write(workspace, descriptor) do
      {:ok, path} -> args ++ ["--mcp-config", shell_escape(path)]
      {:error, _reason} -> args
    end
  end

  defp maybe_add_mcp_config(args, _run_spec), do: args

  defp maybe_add_extra_args(args, extra), do: CymphonyElixir.Agent.append_extra_args(args, extra)

  defp transcript_excerpt(lines), do: CymphonyElixir.Agent.transcript_excerpt(lines)

  defp parse_json_output(lines) do
    case find_last_json_line(lines) do
      nil ->
        {:error, {:no_json_output, transcript_excerpt(lines)}}

      line ->
        case Jason.decode(line) do
          {:ok, %{} = payload} ->
            {:ok,
             %{
               session_id: payload["session_id"],
               result: payload["result"],
               usage: payload["usage"],
               raw: line
             }}

          {:error, decode_error} ->
            {:error, {:json_decode_failed, decode_error, transcript_excerpt([line])}}
        end
    end
  end

  defp parse_stream_json_output(lines, on_message) do
    result =
      Enum.reduce(lines, %{last_result: nil}, fn line, acc ->
        reduce_stream_line(line, acc, on_message)
      end)

    case result.last_result do
      nil ->
        {:error, {:no_result_in_stream, transcript_excerpt(lines)}}

      last_result ->
        {:ok,
         %{
           session_id: last_result["session_id"],
           result: last_result["result"],
           usage: last_result["usage"],
           raw: Jason.encode!(last_result)
         }}
    end
  end

  defp reduce_stream_line(line, acc, on_message) do
    case Jason.decode(line) do
      {:ok, %{} = event} ->
        emit(on_message, %{event: :stream_event, payload: event, raw: line})

        if event["type"] == "result", do: %{acc | last_result: event}, else: acc

      {:error, _} ->
        acc
    end
  end

  defp find_last_json_line(lines) when is_list(lines) do
    lines |> Enum.reverse() |> Enum.find(&json_line?/1)
  end

  defp json_line?(line) when is_binary(line) do
    trimmed = String.trim(line)
    String.starts_with?(trimmed, "{") and String.ends_with?(trimmed, "}")
  end

  defp json_line?(_), do: false

  defp emit(on_message, details) when is_function(on_message, 1) do
    on_message.(Map.put(details, :timestamp, DateTime.utc_now()))
  end

  defp shell_escape(value) when is_binary(value), do: CymphonyElixir.Shell.escape(value)
end
