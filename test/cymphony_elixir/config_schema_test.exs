defmodule CymphonyElixir.ConfigSchemaTest do
  use ExUnit.Case, async: true

  alias CymphonyElixir.Config.Schema

  test "agent section carries kind/model/effort and moved timeouts with defaults" do
    assert {:ok, settings} = Schema.parse(%{})
    assert settings.agent.kind == "claude"
    assert settings.agent.model == nil
    assert settings.agent.effort == nil
    assert settings.agent.turn_timeout_ms == 3_600_000
    assert settings.agent.stall_timeout_ms == 300_000
  end

  test "agent.kind accepts known kinds including antigravity and rejects unknown kinds" do
    kinds = CymphonyElixir.Agent.known_kinds()

    assert kinds == Schema.Agent.changeset(%Schema.Agent{}, %{}) |> kind_inclusion()
    assert "antigravity" in kinds

    for kind <- kinds do
      assert {:ok, settings} = Schema.parse(%{"agent" => %{"kind" => kind}})
      assert settings.agent.kind == kind
    end

    assert {:ok, settings} = Schema.parse(%{"agent" => %{"kind" => "antigravity"}})
    assert settings.agent.kind == "antigravity"

    assert {:error, {:invalid_workflow_config, message}} =
             Schema.parse(%{"agent" => %{"kind" => "gemini"}})

    assert message =~ "kind"
  end

  test "claude section is slim: providers live here, sandbox/approval vestiges are gone" do
    assert {:ok, settings} =
             Schema.parse(%{"claude" => %{"provider" => "cz", "providers" => ["cz", "cv"]}})

    assert settings.claude.command == "claude"
    assert settings.claude.output_format == "stream-json"
    assert settings.claude.provider == "cz"
    assert settings.claude.providers == ["cz", "cv"]
    refute Map.has_key?(settings.claude, :approval_policy)
    refute Map.has_key?(settings.claude, :thread_sandbox)
    refute Map.has_key?(settings.claude, :turn_sandbox_policy)
    refute Map.has_key?(settings.claude, :model)
  end

  test "codex section defaults and sandbox validation" do
    assert {:ok, settings} = Schema.parse(%{})
    assert settings.codex.command == "codex"
    assert settings.codex.sandbox == "workspace-write"
    assert settings.codex.network_access == true
    assert settings.codex.providers == []

    assert {:ok, settings} = Schema.parse(%{"codex" => %{"sandbox" => "read-only"}})
    assert settings.codex.sandbox == "read-only"

    assert {:error, {:invalid_workflow_config, message}} =
             Schema.parse(%{"codex" => %{"sandbox" => "yolo"}})

    assert message =~ "sandbox"
  end

  test "antigravity section defaults to agy/stream-json/skip_permissions" do
    assert {:ok, settings} = Schema.parse(%{})
    assert settings.antigravity.command == "agy"
    assert settings.antigravity.output_format == "stream-json"
    assert settings.antigravity.skip_permissions == true
    assert settings.antigravity.sandbox == false
    assert settings.antigravity.providers == []
    assert settings.antigravity.extra_args == nil
    assert settings.antigravity.print_timeout == nil
    assert settings.antigravity.provider == nil
  end

  test "antigravity new_project defaults on and only an explicit false turns it off" do
    assert {:ok, defaults} = Schema.parse(%{})
    assert defaults.antigravity.new_project == true

    assert {:ok, off} = Schema.parse(%{"antigravity" => %{"new_project" => false}})
    assert off.antigravity.new_project == false

    assert {:ok, on} = Schema.parse(%{"antigravity" => %{"new_project" => true}})
    assert on.antigravity.new_project == true
  end

  test "every agent section accepts extra_args as a string or a list of strings" do
    assert {:ok, settings} =
             Schema.parse(%{
               "claude" => %{"extra_args" => ["--add-dir", "/srv/x"]},
               "codex" => %{"extra_args" => "-c foo=1"},
               "antigravity" => %{"extra_args" => ["--new-project"]}
             })

    assert settings.claude.extra_args == ["--add-dir", "/srv/x"]
    assert settings.codex.extra_args == "-c foo=1"
    assert settings.antigravity.extra_args == ["--new-project"]

    assert {:ok, empty} = Schema.parse(%{"claude" => %{"extra_args" => []}})
    assert empty.claude.extra_args == []

    assert {:ok, cleared} = Schema.parse(%{"claude" => %{"extra_args" => nil}})
    assert cleared.claude.extra_args == nil
  end

  test "extra_args rejects shapes that are neither a string nor a list of strings" do
    for {section, bad} <- [{"claude", 12}, {"codex", ["--ok", 2]}, {"antigravity", %{"a" => 1}}] do
      assert {:error, {:invalid_workflow_config, message}} =
               Schema.parse(%{section => %{"extra_args" => bad}})

      assert message =~ "extra_args"
    end
  end

  test "ExtraArgs casts nil/string/string-list and rejects everything else" do
    assert Schema.ExtraArgs.cast(nil) == {:ok, nil}
    assert Schema.ExtraArgs.cast("--foo bar") == {:ok, "--foo bar"}
    assert Schema.ExtraArgs.cast("") == {:ok, ""}
    assert Schema.ExtraArgs.cast([]) == {:ok, []}
    assert Schema.ExtraArgs.cast(["--a", "--b"]) == {:ok, ["--a", "--b"]}
    assert Schema.ExtraArgs.cast(["--a", 2]) == :error
    assert Schema.ExtraArgs.cast(12) == :error
    assert Schema.ExtraArgs.cast(%{"a" => 1}) == :error
  end

  test "ExtraArgs load/dump round-trip the value unchanged" do
    # Never persisted through a repo, but Ecto.Type requires both callbacks.
    assert Schema.ExtraArgs.type() == :any
    assert Schema.ExtraArgs.load(["--x"]) == {:ok, ["--x"]}
    assert Schema.ExtraArgs.dump(["--x"]) == {:ok, ["--x"]}
  end

  test "Forge casts the known platforms, case- and whitespace-insensitively" do
    assert Schema.Forge.type() == :string
    assert Schema.Forge.kinds() == ["github", "gitlab"]
    assert Schema.Forge.cast("github") == {:ok, "github"}
    assert Schema.Forge.cast("gitlab") == {:ok, "gitlab"}
    assert Schema.Forge.cast("  GitLab  ") == {:ok, "gitlab"}
    assert Schema.Forge.cast(nil) == {:ok, nil}
    assert Schema.Forge.cast("") == {:ok, nil}
    assert Schema.Forge.cast("   ") == {:ok, nil}
  end

  test "Forge treats an unknown platform as unset instead of failing Schema.parse/1" do
    # Same philosophy as LenientBoolean: a typo must not take the project down.
    # `finalize_settings/1` turns the resulting nil back into the default.
    for bad <- ["bitbucket", "gitea", :gitlab, 7, %{}] do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert Schema.Forge.cast(bad) == {:ok, nil}
        end)

      assert log =~ "Ignoring unknown forge"
    end

    assert {:ok, %Schema{forge: "github"}} = Schema.parse(%{"forge" => "bitbucket"})
    assert {:ok, %Schema{forge: "github"}} = Schema.parse(%{})
    assert {:ok, %Schema{forge: "gitlab"}} = Schema.parse(%{"forge" => "gitlab"})
  end

  test "Forge load/dump round-trip the value unchanged" do
    assert Schema.Forge.load("gitlab") == {:ok, "gitlab"}
    assert Schema.Forge.dump("github") == {:ok, "github"}
  end

  test "LenientBoolean casts real booleans and Ecto's string spellings" do
    assert Schema.LenientBoolean.type() == :boolean
    assert Schema.LenientBoolean.cast(true) == {:ok, true}
    assert Schema.LenientBoolean.cast(false) == {:ok, false}
    assert Schema.LenientBoolean.cast(nil) == {:ok, nil}

    assert Schema.LenientBoolean.cast("true") == {:ok, true}
    assert Schema.LenientBoolean.cast("TRUE") == {:ok, true}
    assert Schema.LenientBoolean.cast("1") == {:ok, true}
    assert Schema.LenientBoolean.cast("false") == {:ok, false}
    assert Schema.LenientBoolean.cast("FALSE") == {:ok, false}
    assert Schema.LenientBoolean.cast("0") == {:ok, false}
  end

  test "LenientBoolean treats typos as unset instead of failing Schema.parse/1" do
    # A typo'd boolean must not take the project down. The adapter only drops
    # --new-project on an exact `false`, so nil (unset) keeps the flag on.
    for bad <- [0, 1, "no", "off", "yes", "2", :atom] do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert Schema.LenientBoolean.cast(bad) == {:ok, nil}
        end)

      assert log =~ "Ignoring invalid boolean"
    end
  end

  test "LenientBoolean load/dump round-trip the value unchanged" do
    assert Schema.LenientBoolean.load(true) == {:ok, true}
    assert Schema.LenientBoolean.dump(false) == {:ok, false}
  end

  test "antigravity new_project string spellings parse; invalid values stay unset" do
    assert {:ok, off} = Schema.parse(%{"antigravity" => %{"new_project" => "false"}})
    assert off.antigravity.new_project == false

    assert {:ok, on} = Schema.parse(%{"antigravity" => %{"new_project" => "true"}})
    assert on.antigravity.new_project == true

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:ok, unset} = Schema.parse(%{"antigravity" => %{"new_project" => "no"}})
        refute unset.antigravity.new_project == false
      end)

    assert log =~ "Ignoring invalid boolean"
  end

  test "antigravity accepts extra_args/print_timeout/provider/providers" do
    assert {:ok, settings} =
             Schema.parse(%{
               "antigravity" => %{
                 "extra_args" => "--foo bar",
                 "print_timeout" => "30s",
                 "provider" => "cz",
                 "providers" => ["cz", "cv"]
               }
             })

    assert settings.antigravity.extra_args == "--foo bar"
    assert settings.antigravity.print_timeout == "30s"
    assert settings.antigravity.provider == "cz"
    assert settings.antigravity.providers == ["cz", "cv"]
  end

  test "antigravity rejects unknown output_format" do
    assert {:error, {:invalid_workflow_config, message}} =
             Schema.parse(%{"antigravity" => %{"output_format" => "yaml"}})

    assert message =~ "output_format"
  end

  defp kind_inclusion(changeset) do
    changeset
    |> Ecto.Changeset.validations()
    |> Keyword.get_values(:kind)
    |> Enum.find_value(fn
      {:inclusion, kinds} when is_list(kinds) -> kinds
      _other -> nil
    end)
  end
end
