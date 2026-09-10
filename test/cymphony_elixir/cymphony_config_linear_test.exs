defmodule CymphonyElixir.Cymphony.ConfigLinearTest do
  # async: false — mutates :config_dir_override and LINEAR_API_KEY.
  use ExUnit.Case, async: false

  alias CymphonyElixir.Cymphony.Config, as: CymphonyConfig
  alias CymphonyElixir.Cymphony.Defaults

  @lin_test "lin_test"
  @lin_api_fake "lin_api_fake"

  setup do
    tmp = Path.join(System.tmp_dir!(), "cymphony-linear-cfg-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    Application.put_env(:cymphony_elixir, :config_dir_override, tmp)
    previous_key = System.get_env("LINEAR_API_KEY")
    System.delete_env("LINEAR_API_KEY")

    on_exit(fn ->
      Application.delete_env(:cymphony_elixir, :config_dir_override)

      if previous_key do
        System.put_env("LINEAR_API_KEY", previous_key)
      else
        System.delete_env("LINEAR_API_KEY")
      end

      File.rm_rf!(tmp)
    end)

    {:ok, tmp: tmp, path: Path.join(tmp, "config.json")}
  end

  defp write_config!(path, data) when is_map(data) do
    File.write!(path, Jason.encode!(data))
  end

  defp minimal_project_attrs do
    %{"name" => "Farm", "linear_project_slug" => "ailogic-ced4159f70c4"}
  end

  describe "mask_linear_api_key/1" do
    test "returns only bullets when the trimmed key is shorter than 4 characters" do
      assert CymphonyConfig.mask_linear_api_key("") == "••••"
      assert CymphonyConfig.mask_linear_api_key("ab") == "••••"
      assert CymphonyConfig.mask_linear_api_key("   xy  ") == "••••"
    end

    test "prefixes a fixed bullet mask and appends the last 4 characters" do
      assert CymphonyConfig.mask_linear_api_key("abcd") == "••••abcd"
      assert CymphonyConfig.mask_linear_api_key(@lin_test) == "••••test"
      assert CymphonyConfig.mask_linear_api_key(@lin_api_fake) == "••••fake"
      assert CymphonyConfig.mask_linear_api_key("  #{@lin_test}  ") == "••••test"
    end

    test "never encodes the key length as a run of stars" do
      short = CymphonyConfig.mask_linear_api_key("ab")
      long = CymphonyConfig.mask_linear_api_key(@lin_api_fake)

      assert short == "••••"
      assert long == "••••fake"
      refute String.contains?(short, "*")
      refute String.contains?(long, "*")
      assert String.length(CymphonyConfig.mask_linear_api_key(@lin_test)) == String.length(long)
    end
  end

  describe "resolve_linear_api_key/1" do
    test "returns nil when no config key and no env key are present" do
      assert CymphonyConfig.resolve_linear_api_key(nil) == nil
      assert CymphonyConfig.resolve_linear_api_key(%{}) == nil
      assert CymphonyConfig.resolve_linear_api_key(%{"linear_api_key" => "  "}) == nil
    end

    test "prefers a non-empty top-level config key over projects and env" do
      System.put_env("LINEAR_API_KEY", @lin_api_fake)

      config = %{
        "linear_api_key" => "  #{@lin_test}  ",
        "projects" => [%{"linear_api_key" => @lin_api_fake}]
      }

      assert CymphonyConfig.resolve_linear_api_key(config) == @lin_test
    end

    test "uses the first non-empty project key when the top-level key is absent" do
      config = %{
        "projects" => [
          %{"name" => "missing"},
          %{"name" => "empty", "linear_api_key" => "   "},
          %{"name" => "kept", "linear_api_key" => @lin_api_fake}
        ]
      }

      assert CymphonyConfig.resolve_linear_api_key(config) == @lin_api_fake
    end

    test "falls back to LINEAR_API_KEY when the file has no usable key" do
      System.put_env("LINEAR_API_KEY", "  #{@lin_test}  ")

      assert CymphonyConfig.resolve_linear_api_key(nil) == @lin_test

      assert CymphonyConfig.resolve_linear_api_key(%{"linear_api_key" => "", "projects" => []}) ==
               @lin_test

      assert CymphonyConfig.resolve_linear_api_key(%{"linear_api_key" => 123}) == @lin_test
    end
  end

  describe "linear_key_source/1" do
    test "returns nil when neither the file nor the env has a key" do
      assert CymphonyConfig.linear_key_source(nil) == nil
      assert CymphonyConfig.linear_key_source(%{"projects" => []}) == nil
    end

    test "returns :config when a non-empty key exists at the top level or on any project" do
      System.put_env("LINEAR_API_KEY", @lin_api_fake)

      assert CymphonyConfig.linear_key_source(%{"linear_api_key" => @lin_test}) == :config

      assert CymphonyConfig.linear_key_source(%{
               "projects" => [%{"linear_api_key" => @lin_test}]
             }) == :config
    end

    test "returns :env when only the process environment has a key" do
      System.put_env("LINEAR_API_KEY", @lin_test)

      assert CymphonyConfig.linear_key_source(nil) == :env
      assert CymphonyConfig.linear_key_source(%{"linear_api_key" => "", "projects" => []}) == :env
    end
  end

  describe "put_linear_api_key/1" do
    test "rejects a blank key without writing a file", %{path: path} do
      assert CymphonyConfig.put_linear_api_key("") == {:error, :empty}
      assert CymphonyConfig.put_linear_api_key("   ") == {:error, :empty}
      refute File.exists?(path)
    end

    test "creates config.json when missing, with the shared key and empty projects", %{path: path} do
      assert {:ok, config} = CymphonyConfig.put_linear_api_key("  #{@lin_test}  ")

      assert config == %{"linear_api_key" => @lin_test, "projects" => []}
      assert File.read!(path) == Jason.encode!(config, pretty: true)
      assert File.stat!(path).mode |> Bitwise.band(0o777) == 0o600
    end

    test "stamps the trimmed key onto the top level and every project", %{path: path} do
      write_config!(path, %{
        "theme" => "dark",
        "projects" => [
          %{"name" => "alpha", "linear_api_key" => "old"},
          %{"name" => "beta"}
        ]
      })

      assert {:ok, updated} = CymphonyConfig.put_linear_api_key(@lin_api_fake)
      assert updated["linear_api_key"] == @lin_api_fake
      assert updated["theme"] == "dark"
      assert Enum.all?(updated["projects"], &(&1["linear_api_key"] == @lin_api_fake))
      assert {:ok, ^updated} = CymphonyConfig.load()
    end

    test "leaves a non-list projects value in place while setting the top-level key", %{path: path} do
      write_config!(path, %{"projects" => "legacy"})

      assert {:ok, updated} = CymphonyConfig.put_linear_api_key(@lin_test)
      assert updated["linear_api_key"] == @lin_test
      assert updated["projects"] == "legacy"
    end

    test "returns the load error when config.json exists but is invalid JSON", %{path: path} do
      File.write!(path, "{not json")

      assert {:error, msg} = CymphonyConfig.put_linear_api_key(@lin_test)
      assert msg =~ "Invalid JSON in #{path}"
    end

    test "returns the save error when config.json cannot be written", %{path: path} do
      File.mkdir_p!(path)

      assert {:error, msg} = CymphonyConfig.put_linear_api_key(@lin_test)
      assert msg =~ "Failed to write #{path}"
    end
  end

  describe "add_project/1" do
    test "rejects a blank name or slug as :invalid_project" do
      assert CymphonyConfig.add_project(%{}) == {:error, :invalid_project}
      assert CymphonyConfig.add_project(%{"name" => "Farm"}) == {:error, :invalid_project}

      assert CymphonyConfig.add_project(%{"linear_project_slug" => "slug"}) ==
               {:error, :invalid_project}

      assert CymphonyConfig.add_project(%{"name" => "  ", "linear_project_slug" => "slug"}) ==
               {:error, :invalid_project}

      assert CymphonyConfig.add_project(%{"name" => "Farm", "linear_project_slug" => "   "}) ==
               {:error, :invalid_project}

      assert CymphonyConfig.add_project(%{"name" => 1, "linear_project_slug" => "slug"}) ==
               {:error, :invalid_project}
    end

    test "returns :not_connected when no Linear key is available", %{path: path} do
      assert CymphonyConfig.add_project(minimal_project_attrs()) == {:error, :not_connected}
      refute File.exists?(path)

      write_config!(path, %{"projects" => []})
      assert CymphonyConfig.add_project(minimal_project_attrs()) == {:error, :not_connected}
    end

    test "returns the load error when config.json exists but is invalid JSON", %{path: path} do
      File.write!(path, "{not json")

      assert {:error, msg} = CymphonyConfig.add_project(minimal_project_attrs())
      assert msg =~ "Invalid JSON in #{path}"
    end

    test "inherits a top-level key and applies defaults", %{path: path} do
      write_config!(path, %{"linear_api_key" => @lin_test, "projects" => [], "theme" => "dark"})

      assert {:ok, project} =
               CymphonyConfig.add_project(%{
                 "name" => "  Farm  ",
                 "linear_project_slug" => "  ailogic-ced4159f70c4  "
               })

      assert project == %{
               "name" => "Farm",
               "linear_project_slug" => "ailogic-ced4159f70c4",
               "linear_api_key" => @lin_test,
               "workspace_root" => Path.join(Defaults.workspace_root(), "Farm"),
               "polling_interval_ms" => Defaults.polling_interval_ms()
             }

      {:ok, saved} = CymphonyConfig.load()
      assert saved["linear_api_key"] == @lin_test
      assert saved["theme"] == "dark"
      assert saved["projects"] == [project]
      assert File.stat!(path).mode |> Bitwise.band(0o777) == 0o600
    end

    test "inherits the first project key and copies optional fields", %{path: path} do
      write_config!(path, %{
        "projects" => [%{"name" => "Existing", "linear_api_key" => @lin_api_fake}]
      })

      assert {:ok, project} =
               CymphonyConfig.add_project(%{
                 "name" => "Added",
                 "linear_project_slug" => "added-slug",
                 "github_repo_url" => "  git@github.com:me/repo.git  ",
                 "workspace_root" => "  /tmp/added  ",
                 "polling_interval_ms" => 12_000,
                 "agent" => "codex",
                 "model" => "  gpt-5.2-codex  ",
                 "effort" => "high",
                 "provider" => "oa1",
                 "ignored" => "nope"
               })

      assert project["linear_api_key"] == @lin_api_fake
      assert project["github_repo_url"] == "git@github.com:me/repo.git"
      refute Map.has_key?(project, "repo_url")
      assert project["workspace_root"] == "/tmp/added"
      assert project["polling_interval_ms"] == 12_000
      assert project["agent"] == "codex"
      assert project["model"] == "gpt-5.2-codex"
      assert project["effort"] == "high"
      assert project["provider"] == "oa1"
      refute Map.has_key?(project, "ignored")

      {:ok, saved} = CymphonyConfig.load()
      assert length(saved["projects"]) == 2
      assert List.last(saved["projects"]) == project
    end

    test "add_project persists repo_url and forge when given", %{path: path} do
      write_config!(path, %{
        "projects" => [%{"name" => "Existing", "linear_api_key" => @lin_api_fake}]
      })

      assert {:ok, project} =
               CymphonyConfig.add_project(%{
                 "name" => "GitLab Project",
                 "linear_project_slug" => "glp",
                 "repo_url" => "  https://gitlab.example.com/group/sub/repo.git  ",
                 "forge" => "gitlab"
               })

      assert project["repo_url"] == "https://gitlab.example.com/group/sub/repo.git"
      assert project["forge"] == "gitlab"
      # The legacy key is only written when the caller used it.
      refute Map.has_key?(project, "github_repo_url")
    end

    test "creates config.json from an env key when the file is missing", %{path: path} do
      System.put_env("LINEAR_API_KEY", @lin_test)

      assert {:ok, project} = CymphonyConfig.add_project(minimal_project_attrs())
      assert project["linear_api_key"] == @lin_test
      assert File.regular?(path)

      {:ok, saved} = CymphonyConfig.load()
      assert saved["projects"] == [project]
    end

    test "omits unknown or blank optional agent settings and defaultable blanks", %{path: path} do
      write_config!(path, %{"linear_api_key" => @lin_test, "projects" => []})

      assert {:ok, project} =
               CymphonyConfig.add_project(%{
                 "name" => "Farm",
                 "linear_project_slug" => "farm-slug",
                 "github_repo_url" => "  ",
                 "workspace_root" => "",
                 "polling_interval_ms" => 0,
                 "agent" => "gemini",
                 "model" => "",
                 "effort" => 1,
                 "provider" => nil
               })

      assert project["workspace_root"] == Path.join(Defaults.workspace_root(), "Farm")
      assert project["polling_interval_ms"] == Defaults.polling_interval_ms()
      refute Map.has_key?(project, "github_repo_url")
      refute Map.has_key?(project, "agent")
      refute Map.has_key?(project, "model")
      refute Map.has_key?(project, "effort")
      refute Map.has_key?(project, "provider")
    end

    test "keeps a known agent kind after trim and accepts antigravity", %{path: path} do
      write_config!(path, %{"linear_api_key" => @lin_test, "projects" => []})

      assert {:ok, project} =
               CymphonyConfig.add_project(%{
                 "name" => "Agy",
                 "linear_project_slug" => "agy-slug",
                 "agent" => "  antigravity  "
               })

      assert project["agent"] == "antigravity"
    end

    test "rejects a duplicate name before checking slug", %{path: path} do
      write_config!(path, %{
        "linear_api_key" => @lin_test,
        "projects" => [
          %{"name" => "Farm", "linear_project_slug" => "ailogic-ced4159f70c4"}
        ]
      })

      assert CymphonyConfig.add_project(minimal_project_attrs()) == {:error, :duplicate_name}

      assert CymphonyConfig.add_project(%{
               "name" => "  Farm  ",
               "linear_project_slug" => "other-slug"
             }) == {:error, :duplicate_name}
    end

    test "rejects a duplicate linear_project_slug", %{path: path} do
      write_config!(path, %{
        "linear_api_key" => @lin_test,
        "projects" => [
          %{"name" => "Existing", "linear_project_slug" => "  ailogic-ced4159f70c4  "}
        ]
      })

      assert CymphonyConfig.add_project(minimal_project_attrs()) == {:error, :duplicate_slug}
    end

    test "appends onto a normalized legacy flat file", %{path: path} do
      write_config!(path, %{
        "linear_project_slug" => "farm",
        "linear_api_key" => @lin_test
      })

      assert {:ok, project} =
               CymphonyConfig.add_project(%{
                 "name" => "Second",
                 "linear_project_slug" => "second-slug"
               })

      {:ok, saved} = CymphonyConfig.load()
      assert Enum.map(saved["projects"], & &1["name"]) == ["farm", "Second"]
      assert List.last(saved["projects"]) == project
    end

    test "replaces a non-list projects value with the new project list", %{path: path} do
      write_config!(path, %{"linear_api_key" => @lin_test, "projects" => "legacy"})

      assert {:ok, project} = CymphonyConfig.add_project(minimal_project_attrs())
      {:ok, saved} = CymphonyConfig.load()
      assert saved["projects"] == [project]
    end

    test "returns the save error when config.json cannot be written", %{path: path} do
      System.put_env("LINEAR_API_KEY", @lin_test)
      File.mkdir_p!(path)

      assert {:error, msg} = CymphonyConfig.add_project(minimal_project_attrs())
      assert msg =~ "Failed to write #{path}"
    end
  end

  describe "to_schema_map/1 linear mapping" do
    test "still sources tracker.api_key from the project linear_api_key" do
      map =
        CymphonyConfig.to_schema_map(%{
          "linear_api_key" => @lin_test,
          "linear_project_slug" => "ailogic-ced4159f70c4"
        })

      assert map["tracker"]["api_key"] == @lin_test
      assert map["tracker"]["project_slug"] == "ailogic-ced4159f70c4"
    end
  end
end
