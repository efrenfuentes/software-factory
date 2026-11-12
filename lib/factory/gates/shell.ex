defmodule Factory.Gates.Shell do
  @moduledoc "Runs the stack's setup, test and lint commands in the issue's worktree."
  @behaviour Factory.Gates
  alias Factory.{Shell, Stacks}

  @timeout :timer.minutes(30)

  @impl true
  def setup(project, issue, path) do
    run_all([Stacks.commands(project, path).setup], issue, path)
  end

  @impl true
  def check(project, issue, path) do
    commands = Stacks.commands(project, path)
    run_all([commands.test, commands.lint], issue, path)
  end

  defp run_all(commands, issue, path) do
    commands
    |> Enum.reject(&is_nil/1)
    |> Enum.reduce_while(:ok, fn command, :ok ->
      case Shell.sh(command, cd: path, env: env(issue), timeout: @timeout) do
        {:ok, _} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, "`#{command}` failed — #{Shell.describe(reason)}"}}
      end
    end)
  end

  # Gives each issue its own test database where the stack supports partitioning,
  # so issues worked on in parallel do not share one.
  defp env(issue) do
    [
      {"MIX_TEST_PARTITION", "_issue#{issue.number}"},
      {"TEST_ENV_NUMBER", "_issue#{issue.number}"},
      {"CI", "true"}
    ]
  end
end
