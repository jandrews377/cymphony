defmodule CymphonyElixir.BurritoCLI do
  @moduledoc """
  OTP Application entrypoint for the Burrito-wrapped standalone binary.
  Starts the full Cymphony supervision tree, then hands off to CLI.main/1.
  """

  use Application

  alias Burrito.Util.Args
  alias CymphonyElixir.Application, as: CymphonyApplication
  alias CymphonyElixir.CLI

  require Logger

  @impl true
  def start(_type, _args) do
    :ok = CymphonyElixir.LogFile.configure()
    children = CymphonyApplication.children()

    with {:ok, sup_pid} <-
           Supervisor.start_link(children, strategy: :one_for_one, name: CymphonyElixir.Supervisor) do
      Task.start(__MODULE__, :run_cli, [cli_args()])

      {:ok, sup_pid}
    end
  end

  @doc """
  CLI arguments for this boot: real argv, else `CYMPHONY_ARGS`.

  An OTP release's `bin/<name> start` does not forward arguments to the
  application, so under a container image built from the `cymphony_docker`
  release `Args.argv/0` is always empty and no CLI command — `setup`, `list`,
  `logs`, `--project` — can be reached. `CYMPHONY_ARGS` is that missing
  channel. It is read only when argv is empty, so the Burrito binary (where
  argv works) is unaffected.
  """
  @spec cli_args() :: [String.t()]
  def cli_args do
    case Args.argv() do
      [] -> env_args()
      argv -> argv
    end
  end

  @doc """
  Splits `CYMPHONY_ARGS` on whitespace, honoring single and double quotes.

  Quoting matters: a project name or a model slug can contain spaces, and
  `CYMPHONY_ARGS='project "My Project" cr 3'` has to reach `OptionParser` as
  three arguments, not four.
  """
  @spec split_args(String.t()) :: [String.t()]
  def split_args(value) when is_binary(value) do
    "\"([^\"]*)\"|'([^']*)'|(\\S+)"
    |> Regex.compile!()
    |> Regex.scan(value, capture: :all_but_first)
    |> Enum.map(&Enum.join/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp env_args do
    case System.get_env("CYMPHONY_ARGS") do
      value when is_binary(value) -> split_args(value)
      _ -> []
    end
  end

  @doc false
  @spec run_cli([String.t()]) :: no_return()
  def run_cli(args) do
    CLI.main(args)
  catch
    kind, reason ->
      Logger.error("Unhandled CLI error: #{inspect({kind, reason})}")
      # `CLI.halt/1`, never `System.halt/1`: this is the only record of a crash
      # in the shipped binary, `LogFile.configure/0` has already removed the
      # console handler, and the disk handlers buffer — halting directly drops
      # the line this just logged and leaves the operator with exit 1 and empty
      # logs.
      CLI.halt(1)
  end

  @impl true
  def stop(_state) do
    CymphonyElixir.StatusDashboard.render_offline_status()
    :ok
  end
end
