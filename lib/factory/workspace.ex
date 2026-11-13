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
  @doc """
  The commit the issue's branch points to, when the worktree is on that branch.
  What is checked for secrets and what is pushed is always this commit.
  """
  @callback head(path :: String.t(), Issue.t()) :: {:ok, sha :: String.t()} | {:error, String.t()}
  @callback code_changed?(path :: String.t(), Project.t(), sha :: String.t()) :: boolean()
  @doc "Publishes `sha` as the issue's branch on origin."
  @callback push(path :: String.t(), Issue.t(), sha :: String.t()) :: :ok | {:error, String.t()}
  @doc """
  What a push of `sha` would send, as blocks of text to search for secret
  values: the message of each commit not pushed yet, and each run of
  consecutive added lines of one hunk. It fails when that cannot be read reliably.
  """
  @callback unpushed_changes(path :: String.t(), Project.t(), Issue.t(), sha :: String.t()) ::
              {:ok, [String.t()]} | {:error, String.t()}
  @callback cleanup(Project.t(), Issue.t()) :: :ok
  @callback read_plan(Project.t(), Issue.t()) :: [%{name: String.t(), content: String.t()}]

  def impl, do: Application.fetch_env!(:factory, :workspace)

  @doc """
  The plan files as the panel shows them: read from the issue's branch, which
  may hold commits whose push was refused for a secret, so every secret value
  is replaced, or the content hidden when the secrets cannot be decrypted.
  """
  def shown_plan(%Project{} = project, %Issue{} = issue) do
    Factory.Secrets.redact_files(project, impl().read_plan(project, issue))
  end

  @doc "Directory, relative to the repository root, holding the issue's spec, plan and tasks."
  def plan_dir(%Issue{number: number}), do: ".factory/issue-#{number}"
  def plan_files, do: ~w(spec.md plan.md tasks.md)
end
