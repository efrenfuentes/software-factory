defmodule Factory.Workspace do
  @moduledoc """
  The checkout an issue is worked on in: the factory's own clone of the
  repository plus one git worktree and branch per issue.
  """
  alias Factory.Pipeline.Issue
  alias Factory.Projects.Project

  @callback prepare(Project.t(), Issue.t()) :: {:ok, path :: String.t()} | {:error, String.t()}
  @callback plan_ready?(path :: String.t(), Issue.t()) :: boolean()
  @callback commit(path :: String.t(), message :: String.t(), opts :: keyword()) ::
              :ok | {:error, String.t()}
  @callback code_changed?(path :: String.t(), Project.t()) :: boolean()
  @callback push(path :: String.t(), Issue.t()) :: :ok | {:error, String.t()}
  @doc """
  What a push would send, as blocks of text to search for secret values: the
  message of each commit not pushed yet, and each run of consecutive added lines
  of one hunk. It fails when that cannot be read reliably.
  """
  @callback unpushed_changes(path :: String.t(), Project.t(), Issue.t()) ::
              {:ok, [String.t()]} | {:error, String.t()}
  @callback cleanup(Project.t(), Issue.t()) :: :ok
  @callback read_plan(Project.t(), Issue.t()) :: [%{name: String.t(), content: String.t()}]

  def impl, do: Application.fetch_env!(:factory, :workspace)

  @doc "Directory, relative to the repository root, holding the issue's spec, plan and tasks."
  def plan_dir(%Issue{number: number}), do: ".factory/issue-#{number}"
  def plan_files, do: ~w(spec.md plan.md tasks.md)
end
