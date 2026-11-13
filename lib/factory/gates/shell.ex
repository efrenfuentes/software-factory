defmodule Factory.Gates.Shell do
  @moduledoc """
  Runs the stack's setup, test and lint commands in the issue's worktree, with
  all the project's secrets in their environment. Their output comes back with
  the secret values replaced.
  """
  @behaviour Factory.Gates
  alias Factory.{Secrets, Shell, Stacks}

  @timeout :timer.minutes(30)

  @impl true
  def setup(project, issue, path) do
    run_all([Stacks.commands(project, path).setup], project, issue, path)
  end

  @impl true
  def check(project, issue, path) do
    commands = Stacks.commands(project, path)
    run_all([commands.test, commands.lint], project, issue, path)
  end

  defp run_all(commands, project, issue, path) do
    env = env(issue) ++ Secrets.env(project.secrets, :checks)

    commands
    |> Enum.reject(&is_nil/1)
    |> Enum.reduce_while(:ok, fn command, :ok ->
      case Shell.sh(command, cd: path, env: env, timeout: @timeout) do
        {:ok, _} ->
          {:cont, :ok}

        {:error, reason} ->
          # Replaced before `describe/1` cuts it, so no piece of a value is left.
          reason = Secrets.redact(project.secrets, reason)
          {:halt, {:error, "`#{command}` failed — #{Shell.describe(reason)}"}}
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
