defmodule Factory.Fakes.Workspace do
  @moduledoc "A workspace where every git operation succeeds, and commits and pushes are recorded."
  @behaviour Factory.Workspace
  alias Factory.Fakes.State

  def commits, do: State.get(:commits) |> Enum.reverse()
  def pushes, do: State.get(:pushes) |> Enum.reverse()

  @impl true
  def prepare(_project, issue),
    do: {:ok, Path.join(System.tmp_dir!(), "factory-fake-#{issue.number}")}

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
    State.update(:pushes, &[issue.number | &1])
    :ok
  end

  @impl true
  def cleanup(_project, _issue), do: :ok
  @impl true
  def read_plan(_project, _issue), do: State.get(:plan)
end
