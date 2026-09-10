defmodule CymphonyElixir.PromptBranchTest do
  @moduledoc """
  Without an explicit rule the agent invents a branch name per run
  (`HC-1-hello-world-static-page`), which is neither predictable nor greppable.
  """
  use CymphonyElixir.TestSupport

  alias CymphonyElixir.Config.Schema
  alias CymphonyElixir.Cymphony.PromptTemplate

  defp issue(overrides \\ %{}) do
    struct(
      %Issue{identifier: "HC-1", title: "Create a simple hello world app", state: "Open", url: "u", description: "d"},
      overrides
    )
  end

  test "defaults to the bare issue identifier" do
    assert PromptBuilder.branch_name(issue(), nil) == "HC-1"
    assert PromptBuilder.branch_name(issue(), "{{ issue.identifier }}") == "HC-1"
  end

  test "a project can use the tracker's own suggestion or any other shape" do
    linear = issue(%{branch_name: "jeremy/hc-1-hello-world"})

    assert PromptBuilder.branch_name(linear, "{{ issue.branch_name }}") == "jeremy/hc-1-hello-world"
    assert PromptBuilder.branch_name(issue(), "feature/{{ issue.identifier }}") == "feature/HC-1"
  end

  test "renders a legal git ref out of whatever the template produces" do
    assert PromptBuilder.branch_name(issue(), "{{ issue.identifier }} {{ issue.title }}") ==
             "HC-1-Create-a-simple-hello-world-app"

    assert PromptBuilder.sanitize_branch("  spaced   out  ") == "spaced-out"
    assert PromptBuilder.sanitize_branch("has:colon?and*globs[") == "hascolonandglobs"
    assert PromptBuilder.sanitize_branch("/leading/and/trailing/") == "leading/and/trailing"
    assert PromptBuilder.sanitize_branch("dots..collapse") == "dots.collapse"
    assert PromptBuilder.sanitize_branch("--edges--") == "edges"
  end

  test "falls back to the identifier rather than failing the run" do
    # An empty render, or a template referencing something that does not exist,
    # must not take the prompt down.
    assert PromptBuilder.branch_name(issue(), "") == "HC-1"
    assert PromptBuilder.branch_name(issue(), "{{ issue.nonexistent }}") == "HC-1"

    log = ExUnit.CaptureLog.capture_log(fn -> assert PromptBuilder.branch_name(issue(), "{% bad %}") == "HC-1" end)
    assert log =~ "Ignoring invalid branch_name_template"
  end

  test "the rendered prompt names the branch and nothing else" do
    {:ok, config} = Schema.parse(%{"tracker" => %{"kind" => "youtrack"}, "branch_name_template" => "{{ issue.identifier }}"})

    prompt = PromptBuilder.build_prompt(issue(), prompt_template: PromptTemplate.get(), config: config)

    assert prompt =~ "Name the working branch exactly `HC-1`."
    assert prompt =~ "Do not add a description,"
    assert prompt =~ "a prefix or a suffix to it."
    assert prompt =~ "Create a fresh branch named exactly `HC-1`"
  end
end
