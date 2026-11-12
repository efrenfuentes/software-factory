defmodule Factory.Fakes.Workspace do
  @moduledoc "A workspace where every git operation succeeds."
  @behaviour Factory.Workspace

  @impl true
  def prepare(_project, issue),
    do: {:ok, Path.join(System.tmp_dir!(), "factory-fake-#{issue.number}")}

  @impl true
  def plan_ready?(_path, _issue), do: true
  @impl true
  def commit(_path, _message, _opts), do: :ok
  @impl true
  def code_changed?(_path, _project), do: Factory.Fakes.State.get(:code_changed?)
  @impl true
  def push(_path, _issue), do: :ok
  @impl true
  def cleanup(_project, _issue), do: :ok
end
