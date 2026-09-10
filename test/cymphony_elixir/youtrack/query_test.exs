defmodule CymphonyElixir.YouTrack.QueryTest do
  use ExUnit.Case, async: true

  alias CymphonyElixir.YouTrack.Query

  describe "issues/2" do
    test "braces the project and every state so multi-word values parse" do
      assert Query.issues("LLM", ["Todo", "In Progress"]) ==
               "project: {LLM} State: {Todo}, {In Progress}"
    end

    test "drops the state clause when no usable state is given" do
      assert Query.issues("LLM", []) == "project: {LLM}"
      assert Query.issues("LLM", ["", "   "]) == "project: {LLM}"
      assert Query.issues("LLM", [nil, 42]) == "project: {LLM}"
    end

    test "strips braces out of values so a stray one cannot end the clause early" do
      assert Query.issues("A{B}C", ["In {Progress}"]) == "project: {ABC} State: {In Progress}"
    end
  end

  describe "normalize_state/1" do
    test "trims and downcases" do
      assert Query.normalize_state("  In Progress ") == "in progress"
    end

    test "treats blank and non-binary values as absent" do
      assert Query.normalize_state("   ") == nil
      assert Query.normalize_state(nil) == nil
      assert Query.normalize_state(42) == nil
    end
  end
end
