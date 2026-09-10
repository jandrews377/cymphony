defmodule CymphonyElixir.BurritoCliArgsTest do
  @moduledoc """
  An OTP release's `bin/<name> start` does not forward arguments, so the
  container image has no argv at all. `CYMPHONY_ARGS` is the channel that makes
  `setup`, `list` and the run flags reachable there.
  """
  use ExUnit.Case, async: false

  alias CymphonyElixir.BurritoCLI

  setup do
    # Outside a Burrito wrapper `Args.argv/0` reads `System.argv/0`, which under
    # `mix test` is the test invocation itself. Blank it so the release case
    # (no argv at all) is what gets exercised.
    original_argv = System.argv()
    System.argv([])

    on_exit(fn ->
      System.argv(original_argv)
      System.delete_env("CYMPHONY_ARGS")
    end)

    :ok
  end

  describe "split_args/1" do
    test "splits on whitespace" do
      assert BurritoCLI.split_args("setup") == ["setup"]
      assert BurritoCLI.split_args("cr 3 c cv1,cz2") == ["cr", "3", "c", "cv1,cz2"]
    end

    test "keeps quoted arguments together" do
      # A project name or model slug with a space has to arrive as one argument.
      assert BurritoCLI.split_args(~s(project "My Project" cr 3)) == ["project", "My Project", "cr", "3"]
      assert BurritoCLI.split_args(~s(model 'claude opus')) == ["model", "claude opus"]
    end

    test "collapses blank input to no arguments" do
      assert BurritoCLI.split_args("") == []
      assert BurritoCLI.split_args("   ") == []
      assert BurritoCLI.split_args(~s("" '')) == []
    end
  end

  describe "cli_args/0" do
    test "reads CYMPHONY_ARGS when the release supplies no argv" do
      System.put_env("CYMPHONY_ARGS", "project Farm cr 2")

      assert BurritoCLI.cli_args() == ["project", "Farm", "cr", "2"]
    end

    test "is empty when neither argv nor the env var is set" do
      System.delete_env("CYMPHONY_ARGS")

      assert BurritoCLI.cli_args() == []
    end

    test "real argv wins, so the Burrito binary is unaffected by the env var" do
      System.argv(["--version"])
      System.put_env("CYMPHONY_ARGS", "setup")

      assert BurritoCLI.cli_args() == ["--version"]
    end
  end
end
