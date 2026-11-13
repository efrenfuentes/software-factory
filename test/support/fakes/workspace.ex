defmodule Factory.Fakes.Workspace do
  @moduledoc "A workspace where every git operation succeeds, and commits and pushes are recorded."
  @behaviour Factory.Workspace
  alias Factory.Fakes.State

  def commits, do: State.get(:commits) |> Enum.reverse()
  def pushes, do: State.get(:pushes) |> Enum.reverse()

  @doc "Runs `fun` once, in the caller, when the next `prepare/2` starts."
  def during_prepare(fun), do: State.update(:workspace_hooks, &Map.put(&1, :prepare, fun))

  @doc """
  Makes the next push fail with what `Factory.Workspace.Git` returns for a git
  error with `output`, worked out during the call (so in the stage's process).
  """
  def fail_push(output), do: State.put(:push_failure, output)

  @doc "What `unpushed_changes/3` answers from now on: a list of blocks or `{:error, message}`."
  def set_unpushed(blocks_or_error), do: State.put(:unpushed, blocks_or_error)

  @impl true
  def prepare(_project, issue) do
    State.run_hook(:workspace_hooks, :prepare)
    {:ok, Path.join(System.tmp_dir!(), "factory-fake-#{issue.number}")}
  end

  @impl true
  def plan_ready?(_path, _issue), do: true
  @impl true
  def commit(_path, message, _opts) do
    State.update(:commits, &[message | &1])
    :ok
  end

  @impl true
  def code_changed?(_path, _project), do: State.get(:code_changed?)
  @impl true
  def push(_path, issue) do
    case State.get(:push_failure) do
      nil ->
        State.update(:pushes, &[issue.number | &1])
        :ok

      output ->
        State.put(:push_failure, nil)
        {:error, Factory.Shell.describe({:exit, 1, output})}
    end
  end

  @impl true
  def unpushed_changes(_path, _project, _issue) do
    case State.get(:unpushed) do
      {:error, _} = error -> error
      blocks -> {:ok, blocks}
    end
  end

  @impl true
  def cleanup(_project, _issue), do: :ok
  @impl true
  def read_plan(_project, _issue), do: State.get(:plan)
end
