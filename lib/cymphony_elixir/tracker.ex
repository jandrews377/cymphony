defmodule CymphonyElixir.Tracker do
  @moduledoc """
  Adapter boundary for issue tracker reads and writes.
  """

  alias CymphonyElixir.Config

  @callback fetch_candidate_issues() :: {:ok, [term()]} | {:error, term()}
  @callback fetch_issues_by_states([String.t()]) :: {:ok, [term()]} | {:error, term()}
  @callback fetch_issue_states_by_ids([String.t()]) :: {:ok, [term()]} | {:error, term()}
  @callback create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  @callback create_comment(String.t(), String.t(), term()) :: :ok | {:error, term()}
  @callback update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}

  @spec fetch_candidate_issues() :: {:ok, [term()]} | {:error, term()}
  def fetch_candidate_issues do
    adapter().fetch_candidate_issues()
  end

  @spec fetch_candidate_issues(Config.Schema.t()) :: {:ok, [term()]} | {:error, term()}
  def fetch_candidate_issues(config) when is_struct(config, Config.Schema) do
    adapter(config).fetch_candidate_issues(config)
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issues_by_states(states) do
    adapter().fetch_issues_by_states(states)
  end

  @spec fetch_issues_by_states([String.t()], Config.Schema.t()) :: {:ok, [term()]} | {:error, term()}
  def fetch_issues_by_states(states, config) when is_struct(config, Config.Schema) do
    adapter(config).fetch_issues_by_states(states, config)
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) do
    adapter().fetch_issue_states_by_ids(issue_ids)
  end

  @spec fetch_issue_states_by_ids([String.t()], Config.Schema.t()) :: {:ok, [term()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids, config) when is_struct(config, Config.Schema) do
    adapter(config).fetch_issue_states_by_ids(issue_ids, config)
  end

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) do
    adapter().create_comment(issue_id, body)
  end

  @spec create_comment(String.t(), String.t(), Config.Schema.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body, config) when is_struct(config, Config.Schema) do
    adapter(config).create_comment(issue_id, body, config)
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name) do
    adapter().update_issue_state(issue_id, state_name)
  end

  @spec update_issue_state(String.t(), String.t(), Config.Schema.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name, config) when is_struct(config, Config.Schema) do
    adapter(config).update_issue_state(issue_id, state_name, config)
  end

  @spec adapter() :: module()
  def adapter do
    case Config.settings!().tracker.kind do
      "memory" -> CymphonyElixir.Tracker.Memory
      "youtrack" -> CymphonyElixir.YouTrack.Adapter
      _ -> CymphonyElixir.Linear.Adapter
    end
  end

  @spec adapter(Config.Schema.t()) :: module()
  def adapter(config) do
    case config.tracker.kind do
      "memory" -> CymphonyElixir.Tracker.Memory
      "youtrack" -> CymphonyElixir.YouTrack.Adapter
      _ -> CymphonyElixir.Linear.Adapter
    end
  end
end
