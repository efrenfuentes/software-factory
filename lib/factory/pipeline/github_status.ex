defmodule Factory.Pipeline.GitHubStatus do
  @moduledoc """
  Shows on the GitHub issue where the factory is with it: a label while it is
  in progress, another once its pull request is open, and the issue closed when
  the pull request is merged.

  GitHub only does this by itself for pull requests into the default branch
  (through "Closes #N"), so the factory does it for every base branch.
  """
  require Logger
  alias Factory.{GitHub, Repo}
  alias Factory.Pipeline.Issue

  @in_progress "factory:in-progress"
  @in_review "factory:in-review"
  @merged "factory:merged"

  def in_progress_label, do: @in_progress
  def in_review_label, do: @in_review
  def merged_label, do: @merged

  @doc "The status label an issue should carry, if any."
  def label(%Issue{state: state}) when state in ~w(queued done cancelled), do: nil
  def label(%Issue{pr_number: number}) when not is_nil(number), do: @in_review
  def label(%Issue{}), do: @in_progress

  @doc """
  Brings GitHub in line after an issue moved from `before` to `now`. GitHub is
  only called when something changes, and a failure there never stops the issue.
  """
  def sync(%Issue{} = before, %Issue{} = now) do
    now = Repo.preload(now, :project)
    repo = now.project.repo
    {old, new} = {label(before), label(now)}

    if old != new do
      if old, do: GitHub.impl().set_label(repo, now.number, old, false)
      # A cancellation may have landed since this transition: never label a stopped issue.
      if new && not Factory.Pipeline.stopped?(now),
        do: GitHub.impl().set_label(repo, now.number, new, true)
    end

    if now.state == "done" and before.state != "done", do: merged(now)
    :ok
  rescue
    exception ->
      Logger.warning(
        "Could not update the status of issue #{now.id} on GitHub: " <>
          Exception.message(exception)
      )

      :ok
  end

  defp merged(%Issue{project: %{close_issue_on_merge: false} = project} = issue) do
    GitHub.impl().set_label(project.repo, issue.number, @merged, true)
  end

  defp merged(%Issue{project: project} = issue) do
    # GitHub already closed it if the pull request went into the default branch.
    with {:ok, %{state: "OPEN"}} <- GitHub.impl().get_issue(project.repo, issue.number) do
      GitHub.impl().close_issue(
        project.repo,
        issue.number,
        GitHub.sign(
          "Pull request ##{issue.pr_number} was merged into `#{project.base_branch}`. Closing this issue."
        )
      )
    end
  end
end
