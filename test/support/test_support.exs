defmodule CymphonyElixir.TestSupport do
  @workflow_prompt "You are an agent for this repository."

  defmacro __using__(_opts) do
    quote do
      use ExUnit.Case
      import ExUnit.CaptureLog

      alias CymphonyElixir.Agent.Runner
      alias CymphonyElixir.AgentRunner
      alias CymphonyElixir.CLI
      alias CymphonyElixir.Config
      alias CymphonyElixir.HttpServer
      alias CymphonyElixir.Linear.Client
      alias CymphonyElixir.Linear.Issue
      alias CymphonyElixir.Orchestrator
      alias CymphonyElixir.PromptBuilder
      alias CymphonyElixir.StatusDashboard
      alias CymphonyElixir.Tracker
      alias CymphonyElixir.Workflow
      alias CymphonyElixir.WorkflowStore
      alias CymphonyElixir.Workspace

      import CymphonyElixir.TestSupport,
        only: [
          write_workflow_file!: 1,
          write_workflow_file!: 2,
          restore_env: 2,
          stop_default_http_server: 0,
          stop_all_projects: 0
        ]

      setup do
        stop_all_projects()

        workflow_root =
          Path.join(
            System.tmp_dir!(),
            "cymphony-elixir-workflow-#{System.unique_integer([:positive])}"
          )

        File.mkdir_p!(workflow_root)
        workflow_file = Path.join(workflow_root, "WORKFLOW.md")
        write_workflow_file!(workflow_file)
        Workflow.set_workflow_file_path(workflow_file)
        if Process.whereis(CymphonyElixir.WorkflowStore), do: CymphonyElixir.WorkflowStore.force_reload()
        stop_default_http_server()

        on_exit(fn ->
          Application.delete_env(:cymphony_elixir, :workflow_file_path)
          Application.delete_env(:cymphony_elixir, :server_port_override)
          Application.delete_env(:cymphony_elixir, :memory_tracker_issues)
          Application.delete_env(:cymphony_elixir, :memory_tracker_error)
          Application.delete_env(:cymphony_elixir, :memory_tracker_recipient)
          File.rm_rf(workflow_root)
        end)

        :ok
      end
    end
  end

  def write_workflow_file!(path, overrides \\ []) do
    workflow = workflow_content(overrides)
    File.write!(path, workflow)

    if Process.whereis(CymphonyElixir.WorkflowStore) do
      try do
        CymphonyElixir.WorkflowStore.force_reload()
      catch
        :exit, _reason -> :ok
      end
    end

    :ok
  end

  def restore_env(key, nil), do: System.delete_env(key)
  def restore_env(key, value), do: System.put_env(key, value)

  def stop_default_http_server do
    case Enum.find(Supervisor.which_children(CymphonyElixir.Supervisor), fn
           {CymphonyElixir.HttpServer, _pid, _type, _modules} -> true
           _child -> false
         end) do
      {CymphonyElixir.HttpServer, pid, _type, _modules} when is_pid(pid) ->
        :ok = Supervisor.terminate_child(CymphonyElixir.Supervisor, CymphonyElixir.HttpServer)

        if Process.alive?(pid) do
          Process.exit(pid, :normal)
        end

        :ok

      _ ->
        :ok
    end
  end

  def stop_all_projects do
    for name <- CymphonyElixir.ProjectSupervisor.list_project_names() do
      case CymphonyElixir.ProjectSupervisor.lookup(name, :supervisor) do
        nil -> :ok
        pid -> Supervisor.stop(pid, :normal)
      end
    end
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp workflow_content(overrides) do
    config =
      Keyword.merge(
        [
          forge: nil,
          forge_token: nil,
          forge_host: nil,
          tracker_kind: "linear",
          tracker_endpoint: "https://api.linear.app/graphql",
          tracker_api_token: "token",
          tracker_project_slug: "project",
          tracker_assignee: nil,
          tracker_queued_states: ["Todo"],
          tracker_in_progress_state: "In Progress",
          tracker_active_states: ["Todo", "In Progress"],
          tracker_terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"],
          poll_interval_ms: 30_000,
          workspace_root: Path.join(System.tmp_dir!(), "cymphony_workspaces"),
          worker_ssh_hosts: [],
          worker_max_concurrent_agents_per_host: nil,
          max_concurrent_agents: 10,
          max_turns: 20,
          max_retry_backoff_ms: 300_000,
          max_retry_attempts: 30,
          failure_state: nil,
          max_concurrent_agents_by_state: %{},
          agent_kind: "claude",
          agent_model: nil,
          agent_effort: nil,
          turn_timeout_ms: 3_600_000,
          stall_timeout_ms: 300_000,
          claude_command: "claude",
          claude_permission_mode: "acceptEdits",
          claude_allowed_tools: "Bash,Read,Edit",
          claude_output_format: "json",
          claude_max_budget_usd: nil,
          claude_max_turns: nil,
          claude_bare_mode: true,
          claude_fallback_model: nil,
          claude_provider: nil,
          claude_providers: [],
          codex_command: "codex",
          codex_sandbox: "workspace-write",
          codex_network_access: true,
          antigravity_command: "agy",
          antigravity_output_format: "stream-json",
          antigravity_skip_permissions: true,
          antigravity_provider: nil,
          antigravity_providers: [],
          hook_after_create: nil,
          hook_before_run: nil,
          hook_after_run: nil,
          hook_before_remove: nil,
          hook_timeout_ms: 60_000,
          observability_enabled: true,
          observability_refresh_ms: 1_000,
          observability_render_interval_ms: 16,
          server_port: nil,
          server_host: nil,
          prompt: @workflow_prompt
        ],
        overrides
      )

    forge = Keyword.get(config, :forge)
    forge_token = Keyword.get(config, :forge_token)
    forge_host = Keyword.get(config, :forge_host)
    tracker_kind = Keyword.get(config, :tracker_kind)
    tracker_endpoint = Keyword.get(config, :tracker_endpoint)
    tracker_api_token = Keyword.get(config, :tracker_api_token)
    tracker_project_slug = Keyword.get(config, :tracker_project_slug)
    tracker_assignee = Keyword.get(config, :tracker_assignee)
    tracker_queued_states = Keyword.get(config, :tracker_queued_states)
    tracker_in_progress_state = Keyword.get(config, :tracker_in_progress_state)
    tracker_active_states = Keyword.get(config, :tracker_active_states)
    tracker_terminal_states = Keyword.get(config, :tracker_terminal_states)
    poll_interval_ms = Keyword.get(config, :poll_interval_ms)
    workspace_root = Keyword.get(config, :workspace_root)
    worker_ssh_hosts = Keyword.get(config, :worker_ssh_hosts)
    worker_max_concurrent_agents_per_host = Keyword.get(config, :worker_max_concurrent_agents_per_host)
    max_concurrent_agents = Keyword.get(config, :max_concurrent_agents)
    max_turns = Keyword.get(config, :max_turns)
    max_retry_backoff_ms = Keyword.get(config, :max_retry_backoff_ms)
    max_retry_attempts = Keyword.get(config, :max_retry_attempts)
    failure_state = Keyword.get(config, :failure_state)
    max_concurrent_agents_by_state = Keyword.get(config, :max_concurrent_agents_by_state)
    agent_kind = Keyword.get(config, :agent_kind)
    agent_model = Keyword.get(config, :agent_model)
    agent_effort = Keyword.get(config, :agent_effort)
    turn_timeout_ms = Keyword.get(config, :turn_timeout_ms)
    stall_timeout_ms = Keyword.get(config, :stall_timeout_ms)
    claude_command = Keyword.get(config, :claude_command)
    claude_permission_mode = Keyword.get(config, :claude_permission_mode)
    claude_allowed_tools = Keyword.get(config, :claude_allowed_tools)
    claude_output_format = Keyword.get(config, :claude_output_format)
    claude_max_budget_usd = Keyword.get(config, :claude_max_budget_usd)
    claude_max_turns = Keyword.get(config, :claude_max_turns)
    claude_bare_mode = Keyword.get(config, :claude_bare_mode)
    claude_fallback_model = Keyword.get(config, :claude_fallback_model)
    claude_provider = Keyword.get(config, :claude_provider)
    claude_providers = Keyword.get(config, :claude_providers)
    codex_command = Keyword.get(config, :codex_command)
    codex_sandbox = Keyword.get(config, :codex_sandbox)
    codex_network_access = Keyword.get(config, :codex_network_access)
    antigravity_command = Keyword.get(config, :antigravity_command)
    antigravity_output_format = Keyword.get(config, :antigravity_output_format)
    antigravity_skip_permissions = Keyword.get(config, :antigravity_skip_permissions)
    antigravity_provider = Keyword.get(config, :antigravity_provider)
    antigravity_providers = Keyword.get(config, :antigravity_providers)
    hook_after_create = Keyword.get(config, :hook_after_create)
    hook_before_run = Keyword.get(config, :hook_before_run)
    hook_after_run = Keyword.get(config, :hook_after_run)
    hook_before_remove = Keyword.get(config, :hook_before_remove)
    hook_timeout_ms = Keyword.get(config, :hook_timeout_ms)
    observability_enabled = Keyword.get(config, :observability_enabled)
    observability_refresh_ms = Keyword.get(config, :observability_refresh_ms)
    observability_render_interval_ms = Keyword.get(config, :observability_render_interval_ms)
    server_port = Keyword.get(config, :server_port)
    server_host = Keyword.get(config, :server_host)
    prompt = Keyword.get(config, :prompt)

    sections =
      [
        "---",
        "forge: #{yaml_value(forge)}",
        "forge_token: #{yaml_value(forge_token)}",
        "forge_host: #{yaml_value(forge_host)}",
        "tracker:",
        "  kind: #{yaml_value(tracker_kind)}",
        "  endpoint: #{yaml_value(tracker_endpoint)}",
        "  api_key: #{yaml_value(tracker_api_token)}",
        "  project_slug: #{yaml_value(tracker_project_slug)}",
        "  assignee: #{yaml_value(tracker_assignee)}",
        "  queued_states: #{yaml_value(tracker_queued_states)}",
        "  in_progress_state: #{yaml_value(tracker_in_progress_state)}",
        "  active_states: #{yaml_value(tracker_active_states)}",
        "  terminal_states: #{yaml_value(tracker_terminal_states)}",
        "polling:",
        "  interval_ms: #{yaml_value(poll_interval_ms)}",
        "workspace:",
        "  root: #{yaml_value(workspace_root)}",
        worker_yaml(worker_ssh_hosts, worker_max_concurrent_agents_per_host),
        "agent:",
        "  kind: #{yaml_value(agent_kind)}",
        "  model: #{yaml_value(agent_model)}",
        "  effort: #{yaml_value(agent_effort)}",
        "  turn_timeout_ms: #{yaml_value(turn_timeout_ms)}",
        "  stall_timeout_ms: #{yaml_value(stall_timeout_ms)}",
        "  max_concurrent_agents: #{yaml_value(max_concurrent_agents)}",
        "  max_turns: #{yaml_value(max_turns)}",
        "  max_retry_backoff_ms: #{yaml_value(max_retry_backoff_ms)}",
        "  max_retry_attempts: #{yaml_value(max_retry_attempts)}",
        "  failure_state: #{yaml_value(failure_state)}",
        "  max_concurrent_agents_by_state: #{yaml_value(max_concurrent_agents_by_state)}",
        "claude:",
        "  command: #{yaml_value(claude_command)}",
        "  permission_mode: #{yaml_value(claude_permission_mode)}",
        "  allowed_tools: #{yaml_value(claude_allowed_tools)}",
        "  output_format: #{yaml_value(claude_output_format)}",
        "  max_budget_usd: #{yaml_value(claude_max_budget_usd)}",
        "  max_turns: #{yaml_value(claude_max_turns)}",
        "  bare_mode: #{yaml_value(claude_bare_mode)}",
        "  fallback_model: #{yaml_value(claude_fallback_model)}",
        "  provider: #{yaml_value(claude_provider)}",
        "  providers: #{yaml_value(claude_providers)}",
        "codex:",
        "  command: #{yaml_value(codex_command)}",
        "  sandbox: #{yaml_value(codex_sandbox)}",
        "  network_access: #{yaml_value(codex_network_access)}",
        "antigravity:",
        "  command: #{yaml_value(antigravity_command)}",
        "  output_format: #{yaml_value(antigravity_output_format)}",
        "  skip_permissions: #{yaml_value(antigravity_skip_permissions)}",
        "  provider: #{yaml_value(antigravity_provider)}",
        "  providers: #{yaml_value(antigravity_providers)}",
        hooks_yaml(hook_after_create, hook_before_run, hook_after_run, hook_before_remove, hook_timeout_ms),
        observability_yaml(observability_enabled, observability_refresh_ms, observability_render_interval_ms),
        server_yaml(server_port, server_host),
        "---",
        prompt
      ]
      |> Enum.reject(&(&1 in [nil, ""]))

    Enum.join(sections, "\n") <> "\n"
  end

  defp yaml_value(value) when is_binary(value) do
    "\"" <> String.replace(value, "\"", "\\\"") <> "\""
  end

  defp yaml_value(value) when is_integer(value), do: to_string(value)
  defp yaml_value(true), do: "true"
  defp yaml_value(false), do: "false"
  defp yaml_value(nil), do: "null"

  defp yaml_value(values) when is_list(values) do
    "[" <> Enum.map_join(values, ", ", &yaml_value/1) <> "]"
  end

  defp yaml_value(values) when is_map(values) do
    "{" <>
      Enum.map_join(values, ", ", fn {key, value} ->
        "#{yaml_value(to_string(key))}: #{yaml_value(value)}"
      end) <> "}"
  end

  defp yaml_value(value), do: yaml_value(to_string(value))

  defp hooks_yaml(nil, nil, nil, nil, timeout_ms), do: "hooks:\n  timeout_ms: #{yaml_value(timeout_ms)}"

  defp hooks_yaml(hook_after_create, hook_before_run, hook_after_run, hook_before_remove, timeout_ms) do
    [
      "hooks:",
      "  timeout_ms: #{yaml_value(timeout_ms)}",
      hook_entry("after_create", hook_after_create),
      hook_entry("before_run", hook_before_run),
      hook_entry("after_run", hook_after_run),
      hook_entry("before_remove", hook_before_remove)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp worker_yaml(ssh_hosts, max_concurrent_agents_per_host)
       when ssh_hosts in [nil, []] and is_nil(max_concurrent_agents_per_host),
       do: nil

  defp worker_yaml(ssh_hosts, max_concurrent_agents_per_host) do
    [
      "worker:",
      ssh_hosts not in [nil, []] && "  ssh_hosts: #{yaml_value(ssh_hosts)}",
      !is_nil(max_concurrent_agents_per_host) &&
        "  max_concurrent_agents_per_host: #{yaml_value(max_concurrent_agents_per_host)}"
    ]
    |> Enum.reject(&(&1 in [nil, false]))
    |> Enum.join("\n")
  end

  defp observability_yaml(enabled, refresh_ms, render_interval_ms) do
    [
      "observability:",
      "  dashboard_enabled: #{yaml_value(enabled)}",
      "  refresh_ms: #{yaml_value(refresh_ms)}",
      "  render_interval_ms: #{yaml_value(render_interval_ms)}"
    ]
    |> Enum.join("\n")
  end

  defp server_yaml(nil, nil), do: nil

  defp server_yaml(port, host) do
    [
      "server:",
      port && "  port: #{yaml_value(port)}",
      host && "  host: #{yaml_value(host)}"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp hook_entry(_name, nil), do: nil

  defp hook_entry(name, command) when is_binary(command) do
    indented =
      command
      |> String.split("\n")
      |> Enum.map_join("\n", &("    " <> &1))

    "  #{name}: |\n#{indented}"
  end
end
