defmodule CymphonyElixir.YouTrack.Issue do
  @moduledoc """
  Normalizes YouTrack REST issue payloads into the orchestrator's issue struct.

  The orchestrator pattern-matches `%CymphonyElixir.Linear.Issue{}` throughout,
  so that struct is the tracker-neutral shape every adapter produces — this
  module fills it from YouTrack's very different JSON rather than introducing a
  second struct the orchestrator would have to learn.

  Two YouTrack-specific mappings are worth knowing:

    * **State, Priority and Assignee are custom fields**, not top-level
      attributes. They are read out of `customFields` by name, so a project
      whose workflow renames "State" will report `state: nil` and never
      dispatch — that is the visible failure, not a silent wrong dispatch.
    * **Priority is an enum name**, while the orchestrator sorts on Linear's
      integer rank (1 is most urgent, 5 is "no priority"). `priority/1` maps
      YouTrack's default enum onto 1..4 and leaves anything unrecognized `nil`,
      which `Orchestrator.Dispatch` ranks last.
  """

  alias CymphonyElixir.Linear.Issue
  alias CymphonyElixir.YouTrack.Query

  @default_state_field "State"
  @priority_field "Priority"
  @assignee_field "Assignee"

  # Link phrases (as seen *from this issue*) that mean "this issue cannot start
  # until the other one is finished". YouTrack ships "Depends" as a default
  # link type; "Subtask of" is deliberately absent — a subtask is not blocked
  # by its parent.
  @blocking_phrases ["depends on", "is blocked by", "blocked by"]

  # `$type` on customFields is what lets a write reuse the field's real type
  # instead of guessing `StateIssueCustomField` (a renamed state field is
  # frequently a plain enum, and the wrong $type is rejected).
  @fields "id,idReadable,summary,description,created,updated,tags(name)," <>
            "customFields($type,name,value(name,login)),links(direction," <>
            "linkType(name,sourceToTarget,targetToSource)," <>
            "issues(id,idReadable,customFields(name,value(name))))"

  @doc """
  The `fields` query parameter selecting everything `normalize/3` reads.

  YouTrack returns only `id` unless every wanted field is named explicitly.
  """
  @spec fields() :: String.t()
  def fields, do: @fields

  @doc """
  Converts one decoded YouTrack issue into an `Issue` struct.

  `base_url` is the instance root (no trailing `/api`) and is used to build the
  human-facing issue URL. `assignee` is the configured routing login, or `nil`
  to route every issue to this worker.
  """
  @spec normalize(map(), String.t()) :: Issue.t() | nil
  def normalize(issue, base_url), do: normalize(issue, base_url, [])

  @doc """
  Converts one decoded YouTrack issue.

  Options:

    * `:assignee` — routing login; only that user's issues are routed to this
      worker. `nil` routes everything.
    * `:state_field` — custom field holding the workflow state. Defaults to
      `"State"`; projects that call it something else (`"Stage"`) must say so,
      or every issue normalizes to `state: nil` and nothing is ever dispatched.
  """
  @spec normalize(map(), String.t(), keyword()) :: Issue.t() | nil
  def normalize(%{} = issue, base_url, opts) when is_binary(base_url) and is_list(opts) do
    case issue["idReadable"] do
      readable when is_binary(readable) and readable != "" ->
        build(issue, readable, base_url, opts)

      _ ->
        nil
    end
  end

  # Junk *data* normalizes to nil — a payload without a readable id is simply
  # not an issue. A wrong *argument type* must not: passing the assignee where
  # opts belongs used to land here and yield nil, which the orchestrator reads
  # as "issue no longer active or visible" and skips the dispatch, silently,
  # forever. Keep the guards so that mistake raises instead.
  def normalize(_issue, base_url, opts) when is_binary(base_url) and is_list(opts), do: nil

  @doc """
  The custom field name holding the workflow state, from `opts`.
  """
  @spec state_field(keyword()) :: String.t()
  def state_field(opts) when is_list(opts) do
    case Keyword.get(opts, :state_field) do
      value when is_binary(value) -> if String.trim(value) == "", do: @default_state_field, else: value
      _ -> @default_state_field
    end
  end

  @doc """
  The `$type` of the named custom field on a decoded issue, when present.

  Writing a state change has to name the field's real type; a renamed state
  field is often a plain enum rather than a `StateIssueCustomField`, and
  YouTrack rejects the wrong one.
  """
  @spec custom_field_type(map(), String.t()) :: String.t() | nil
  def custom_field_type(%{"customFields" => fields}, name) when is_list(fields) do
    fields
    |> Enum.find(&(is_map(&1) and &1["name"] == name))
    |> case do
      %{"$type" => type} when is_binary(type) -> type
      _ -> nil
    end
  end

  def custom_field_type(_issue, _name), do: nil

  @doc """
  Reads the named custom field's `value.name` from a decoded issue.
  """
  @spec custom_field_name(map(), String.t()) :: String.t() | nil
  def custom_field_name(%{"customFields" => fields}, name) when is_list(fields) do
    fields
    |> Enum.find(&(is_map(&1) and &1["name"] == name))
    |> case do
      %{"value" => %{"name" => value}} when is_binary(value) -> value
      _ -> nil
    end
  end

  def custom_field_name(_issue, _name), do: nil

  @doc """
  Maps a YouTrack Priority enum name onto Linear's 1..4 integer rank.
  """
  @spec priority(String.t() | nil) :: 1..4 | nil
  def priority(name) when is_binary(name) do
    case Query.normalize_state(name) do
      value when value in ["show-stopper", "critical", "urgent"] -> 1
      value when value in ["major", "high"] -> 2
      value when value in ["normal", "medium"] -> 3
      value when value in ["minor", "low"] -> 4
      _ -> nil
    end
  end

  def priority(_name), do: nil

  defp build(issue, readable, base_url, opts) do
    assignee = Keyword.get(opts, :assignee)
    state_field = state_field(opts)
    assignee_login = custom_field_login(issue, @assignee_field)

    %Issue{
      id: readable,
      identifier: readable,
      title: issue["summary"],
      description: issue["description"],
      priority: issue |> custom_field_name(@priority_field) |> priority(),
      state: custom_field_name(issue, state_field),
      branch_name: nil,
      url: issue_url(base_url, readable),
      assignee_id: assignee_login,
      blocked_by: blockers(issue, state_field),
      labels: labels(issue),
      assigned_to_worker: assigned_to_worker?(assignee_login, assignee),
      created_at: timestamp(issue["created"]),
      updated_at: timestamp(issue["updated"])
    }
  end

  defp issue_url(base_url, readable), do: String.trim_trailing(base_url, "/") <> "/issue/" <> readable

  defp custom_field_login(%{"customFields" => fields}, name) when is_list(fields) do
    fields
    |> Enum.find(&(is_map(&1) and &1["name"] == name))
    |> case do
      %{"value" => %{"login" => login}} when is_binary(login) -> login
      _ -> nil
    end
  end

  defp custom_field_login(_issue, _name), do: nil

  defp labels(%{"tags" => tags}) when is_list(tags) do
    Enum.flat_map(tags, fn
      %{"name" => name} when is_binary(name) -> [name]
      _ -> []
    end)
  end

  defp labels(_issue), do: []

  defp blockers(%{"links" => links}, state_field) when is_list(links) do
    Enum.flat_map(links, &link_blockers(&1, state_field))
  end

  defp blockers(_issue, _state_field), do: []

  defp link_blockers(%{"issues" => issues} = link, state_field) when is_list(issues) do
    if blocking_link?(link) do
      Enum.flat_map(issues, &blocker_entry(&1, state_field))
    else
      []
    end
  end

  defp link_blockers(_link, _state_field), do: []

  defp blocker_entry(%{} = issue, state_field) do
    [
      %{
        id: issue["idReadable"] || issue["id"],
        identifier: issue["idReadable"],
        state: custom_field_name(issue, state_field)
      }
    ]
  end

  defp blocker_entry(_issue, _state_field), do: []

  # A YouTrack link is stored once and read from both ends: the phrase that
  # applies to *this* issue depends on which end it sits on.
  defp blocking_link?(%{"direction" => direction, "linkType" => %{} = type}) do
    phrase =
      case direction do
        "OUTWARD" -> type["sourceToTarget"]
        "INWARD" -> type["targetToSource"]
        _ -> type["name"]
      end

    Query.normalize_state(phrase) in @blocking_phrases
  end

  defp blocking_link?(_link), do: false

  defp assigned_to_worker?(_login, nil), do: true

  defp assigned_to_worker?(login, configured) when is_binary(login) and is_binary(configured) do
    Query.normalize_state(login) == Query.normalize_state(configured)
  end

  defp assigned_to_worker?(_login, _configured), do: false

  defp timestamp(millis) when is_integer(millis) do
    case DateTime.from_unix(millis, :millisecond) do
      {:ok, datetime} -> datetime
      {:error, _reason} -> nil
    end
  end

  defp timestamp(_millis), do: nil
end
