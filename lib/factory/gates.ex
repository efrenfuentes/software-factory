defmodule Factory.Gates do
  @moduledoc """
  Deterministic checks (tests and lint) run before any review, so review rounds
  are not spent on work that does not even pass its own tests.
  """
  alias Factory.Pipeline.Issue
  alias Factory.Projects.Project

  @callback setup(Project.t(), Issue.t(), path :: String.t()) :: :ok | {:error, String.t()}
  @callback check(Project.t(), Issue.t(), path :: String.t()) :: :ok | {:error, String.t()}

  def impl, do: Application.fetch_env!(:factory, :gates)
end
