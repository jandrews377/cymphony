defmodule CymphonyElixir.YouTrack.IssueTest do
  use ExUnit.Case, async: true

  alias CymphonyElixir.Linear.Issue, as: NormalizedIssue
  alias CymphonyElixir.YouTrack.Issue

  @base "https://example.youtrack.cloud"

  defp raw(overrides \\ %{}) do
    Map.merge(
      %{
        "id" => "2-14",
        "idReadable" => "LLM-51",
        "summary" => "Add YouTrack adapter",
        "description" => "Body text",
        "created" => 1_700_000_000_000,
        "updated" => 1_700_000_060_000,
        "tags" => [%{"name" => "agent:codex"}, %{"noname" => true}],
        "customFields" => [
          %{"name" => "State", "value" => %{"name" => "In Progress"}},
          %{"name" => "Priority", "value" => %{"name" => "Critical"}},
          %{"name" => "Assignee", "value" => %{"login" => "jeremy"}},
          %{"name" => "Estimate", "value" => 30}
        ]
      },
      overrides
    )
  end

  test "fields/0 names every attribute normalize/3 reads" do
    fields = Issue.fields()

    for wanted <- ~w(idReadable summary description created updated tags customFields links) do
      assert String.contains?(fields, wanted)
    end

    # `$type` is what lets a write reuse the state field's real type.
    assert fields =~ "customFields($type,name"
  end

  describe "a project that renames the state field" do
    @stage Map.merge(
             %{"idReadable" => "HC-1", "summary" => "Create a simple hello world app"},
             %{
               "customFields" => [
                 %{"name" => "Stage", "$type" => "StateIssueCustomField", "value" => %{"name" => "Open"}},
                 %{"name" => "Priority", "$type" => "SingleEnumIssueCustomField", "value" => %{"name" => "Normal"}}
               ]
             }
           )

    test "reads the state from the configured field" do
      # Reading "State" on a project that calls it "Stage" yields nil, which
      # never matches an active state and so silently never dispatches.
      assert Issue.normalize(@stage, @base).state == nil
      assert Issue.normalize(@stage, @base, state_field: "Stage").state == "Open"
      assert Issue.normalize(@stage, @base, state_field: "Stage").priority == 3
    end

    test "uses the configured field for blocker states too" do
      blocker = %{"idReadable" => "HC-2", "customFields" => [%{"name" => "Stage", "value" => %{"name" => "Done"}}]}

      linked =
        Map.put(@stage, "links", [
          %{
            "direction" => "INWARD",
            "linkType" => %{"name" => "Depend", "sourceToTarget" => "is required for", "targetToSource" => "depends on"},
            "issues" => [blocker]
          }
        ])

      assert Issue.normalize(linked, @base, state_field: "Stage").blocked_by == [
               %{id: "HC-2", identifier: "HC-2", state: "Done"}
             ]
    end

    test "state_field/1 falls back to State" do
      assert Issue.state_field([]) == "State"
      assert Issue.state_field(state_field: "  ") == "State"
      assert Issue.state_field(state_field: 7) == "State"
      assert Issue.state_field(state_field: "Stage") == "Stage"
    end

    test "custom_field_type/2 reads the field's own $type for the write path" do
      assert Issue.custom_field_type(@stage, "Stage") == "StateIssueCustomField"
      assert Issue.custom_field_type(@stage, "Priority") == "SingleEnumIssueCustomField"
      assert Issue.custom_field_type(@stage, "Nonexistent") == nil
      assert Issue.custom_field_type(%{"customFields" => [%{"name" => "Stage"}]}, "Stage") == nil
      assert Issue.custom_field_type(%{}, "Stage") == nil
    end
  end

  test "normalizes a YouTrack issue into the orchestrator's struct" do
    issue = Issue.normalize(raw(), @base)

    assert %NormalizedIssue{} = issue
    assert issue.id == "LLM-51"
    assert issue.identifier == "LLM-51"
    assert issue.title == "Add YouTrack adapter"
    assert issue.description == "Body text"
    assert issue.state == "In Progress"
    assert issue.priority == 1
    assert issue.assignee_id == "jeremy"
    assert issue.labels == ["agent:codex"]
    assert issue.branch_name == nil
    assert issue.url == "https://example.youtrack.cloud/issue/LLM-51"
    assert issue.blocked_by == []
    assert issue.assigned_to_worker
    assert issue.created_at == ~U[2023-11-14 22:13:20.000Z]
    assert issue.updated_at == ~U[2023-11-14 22:14:20.000Z]
  end

  test "trims a trailing slash off the instance URL" do
    assert Issue.normalize(raw(), @base <> "/").url == "https://example.youtrack.cloud/issue/LLM-51"
  end

  test "a wrong opts argument raises instead of silently normalizing to nil" do
    # Regression: the client passed `tracker.assignee` where opts belongs. The
    # guard turned that into nil, the orchestrator read it as "issue no longer
    # visible", and dispatch was skipped on every tick with no error anywhere.
    assert_raise FunctionClauseError, fn -> Issue.normalize(raw(), @base, nil) end
    assert_raise FunctionClauseError, fn -> Issue.normalize(raw(), @base, "jeremy") end
  end

  test "rejects a payload without a readable id" do
    assert Issue.normalize(Map.delete(raw(), "idReadable"), @base) == nil
    assert Issue.normalize(%{"idReadable" => ""}, @base) == nil
    assert Issue.normalize("not a map", @base) == nil
  end

  test "ignores a timestamp outside the representable range" do
    assert Issue.normalize(raw(%{"created" => 999_999_999_999_999_999}), @base).created_at == nil
  end

  test "leaves missing custom fields, tags and timestamps empty rather than guessing" do
    issue = Issue.normalize(%{"idReadable" => "LLM-9"}, @base)

    assert issue.state == nil
    assert issue.priority == nil
    assert issue.assignee_id == nil
    assert issue.labels == []
    assert issue.created_at == nil
    assert issue.updated_at == nil
    assert issue.assigned_to_worker
  end

  test "ignores custom fields whose value is not an object" do
    assert Issue.custom_field_name(raw(), "Estimate") == nil
    assert Issue.custom_field_name(raw(), "Nonexistent") == nil
    assert Issue.custom_field_name(%{"customFields" => "nope"}, "State") == nil
    assert Issue.custom_field_name(%{"customFields" => ["scalar"]}, "State") == nil
  end

  describe "priority/1" do
    test "maps the default YouTrack enum onto Linear's 1..4 rank" do
      assert Issue.priority("Show-stopper") == 1
      assert Issue.priority("critical") == 1
      assert Issue.priority("Urgent") == 1
      assert Issue.priority("Major") == 2
      assert Issue.priority("High") == 2
      assert Issue.priority("Normal") == 3
      assert Issue.priority("Medium") == 3
      assert Issue.priority("Minor") == 4
      assert Issue.priority("Low") == 4
    end

    test "leaves an unrecognized or absent priority unranked" do
      assert Issue.priority("Whenever") == nil
      assert Issue.priority(nil) == nil
      assert Issue.priority(7) == nil
    end
  end

  describe "assignee routing" do
    test "routes only matching logins when an assignee is configured" do
      assert Issue.normalize(raw(), @base, assignee: "JEREMY").assigned_to_worker
      refute Issue.normalize(raw(), @base, assignee: "someone-else").assigned_to_worker
    end

    test "does not route an unassigned issue to a configured assignee" do
      unassigned = raw(%{"customFields" => [%{"name" => "State", "value" => %{"name" => "Todo"}}]})

      refute Issue.normalize(unassigned, @base, assignee: "jeremy").assigned_to_worker
      assert Issue.normalize(unassigned, @base).assigned_to_worker
    end
  end

  describe "blockers" do
    defp link(direction, type, issues) do
      raw(%{"links" => [%{"direction" => direction, "linkType" => type, "issues" => issues}]})
    end

    @depends %{"name" => "Depends", "sourceToTarget" => "is required for", "targetToSource" => "depends on"}
    @subtask %{"name" => "Subtask", "sourceToTarget" => "parent for", "targetToSource" => "subtask of"}

    test "reads the phrase that applies to this end of the link" do
      blocker = [%{"idReadable" => "LLM-7", "customFields" => [%{"name" => "State", "value" => %{"name" => "Todo"}}]}]

      assert Issue.normalize(link("INWARD", @depends, blocker), @base).blocked_by == [
               %{id: "LLM-7", identifier: "LLM-7", state: "Todo"}
             ]

      assert Issue.normalize(link("OUTWARD", @depends, blocker), @base).blocked_by == []
    end

    test "a subtask is not blocked by its parent" do
      parent = [%{"idReadable" => "LLM-1", "customFields" => []}]

      assert Issue.normalize(link("INWARD", @subtask, parent), @base).blocked_by == []
    end

    test "falls back to the link type name when the direction is unknown" do
      blocker = [%{"id" => "2-9", "customFields" => []}]
      type = %{"name" => "Blocked by", "sourceToTarget" => "x", "targetToSource" => "y"}

      assert Issue.normalize(link("BOTH", type, blocker), @base).blocked_by == [
               %{id: "2-9", identifier: nil, state: nil}
             ]
    end

    test "ignores malformed link entries" do
      malformed =
        raw(%{
          "links" => [
            %{"direction" => "INWARD"},
            "nope",
            %{"issues" => "nope"},
            %{"direction" => "INWARD", "issues" => []},
            %{"direction" => "INWARD", "linkType" => @depends, "issues" => ["not a map"]}
          ]
        })

      assert Issue.normalize(malformed, @base).blocked_by == []
      assert Issue.normalize(raw(%{"links" => "nope"}), @base).blocked_by == []
    end
  end
end
