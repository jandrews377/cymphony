defmodule CymphonyElixir.PromptBuilderForgeTest do
  @moduledoc """
  The default prompt is one document for both forges: everything that differs
  (CLI binary, what a change proposal is called, the review-reading commands)
  is a Liquid variable. A GitLab project must never be told to run `gh`.
  """
  use CymphonyElixir.TestSupport

  alias CymphonyElixir.Config.Schema
  alias CymphonyElixir.Cymphony.PromptTemplate

  defp issue do
    %Issue{
      identifier: "DEMO-1",
      title: "Forge vocabulary",
      description: "n/a",
      state: "In Progress",
      url: "https://example.org/issue/DEMO-1",
      labels: []
    }
  end

  defp render(forge) do
    PromptBuilder.build_prompt(issue(), prompt_template: PromptTemplate.get(), forge: forge)
  end

  test "renders GitHub vocabulary by default" do
    prompt = render(nil)

    assert prompt =~ "Do not call `gh pr merge` directly"
    assert prompt =~ "(`gh pr view --comments`)"
    assert prompt =~ "(`gh api repos/<owner>/<repo>/pulls/<pr>/comments`)"
    assert prompt =~ "please fix merge conflicts on PR"
    assert prompt =~ "GitHub is **not** a valid blocker"
    assert prompt =~ "an attached pull request (PR)"
    refute prompt =~ "glab"
    refute prompt =~ "merge request"
  end

  test "renders GitLab vocabulary for a gitlab project" do
    prompt = render("gitlab")

    assert prompt =~ "Do not call `glab mr merge` directly"
    assert prompt =~ "(`glab mr view --comments`)"
    assert prompt =~ "please fix merge conflicts on MR"
    assert prompt =~ "GitLab is **not** a valid blocker"
    assert prompt =~ "MR feedback sweep protocol"
    assert prompt =~ "an attached merge request (MR)"
    # The whole point: no GitHub CLI invocation survives anywhere.
    refute prompt =~ "gh pr"
    refute prompt =~ "gh api"
    refute prompt =~ "GitHub"
  end

  test "takes the forge from the resolved workflow config when no override is given" do
    {:ok, config} = Schema.parse(%{"forge" => "gitlab"})

    prompt = PromptBuilder.build_prompt(issue(), prompt_template: PromptTemplate.get(), config: config)

    assert prompt =~ "`glab mr merge`"
    refute prompt =~ "gh pr"
  end

  test "an unknown forge falls back to GitHub rather than rendering a broken CLI" do
    assert PromptBuilder.forge_variables("bitbucket")["cli"] == "gh"
    assert PromptBuilder.forge_variables(nil)["cli"] == "gh"
    assert PromptBuilder.forge_variables("gitlab")["cli"] == "glab"
  end

  test "a hand-authored prompt that never mentions a forge still renders" do
    # `strict_variables: true` means the variable must always be supplied, even
    # for a template that does not read it.
    assert PromptBuilder.build_prompt(issue(), prompt_template: "Ticket {{ issue.identifier }}") ==
             "Ticket DEMO-1"
  end
end
