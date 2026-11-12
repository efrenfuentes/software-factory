defmodule Factory.Pipeline.Poller do
  @moduledoc """
  Periodic look at GitHub: picks up issues carrying the project's trigger label
  and, for issues waiting on a person, reacts to their comments and to the PR
  being merged or closed.

  Only people who can label issues can start work, and only comments from the
  project's allowed users are acted on. Commands are `/factory approve`,
  `/factory retry` and `/factory stop`.
  """
  import Ecto.Query
  require Logger
  alias Factory.{GitHub, Pipeline, Projects, Repo, Workspace}
  alias Factory.Pipeline.{Issue, Stages}
  alias Factory.Projects.Project

  def poll do
    for project <- Projects.list_enabled(), do: discover(project)

    for issue <- Pipeline.list_by_state(Issue.waiting_states()),
        issue.project.enabled,
        do: safely(issue, &check/1)

    for issue <- Pipeline.list_by_state(Issue.active_states()), do: reconcile(issue)
    :ok
  end

  def discover(%Project{} = project) do
    case GitHub.impl().list_issues(project.repo, project.trigger_label) do
      {:ok, issues} ->
        tracked = MapSet.new(Pipeline.tracked_numbers(project))
        for issue <- issues, issue.number not in tracked, do: Pipeline.track_issue(project, issue)

      {:error, reason} ->
        Logger.warning("Could not list issues of #{project.repo}: #{inspect(reason)}")
    end
  end

  defp safely(issue, fun) do
    fun.(issue)
  rescue
    exception -> Logger.error("Poll of issue #{issue.id} failed: #{Exception.message(exception)}")
  end

  def check(%Issue{state: "ready_to_merge", project: project} = issue) do
    case GitHub.impl().get_pr(project.repo, issue.pr_number) do
      {:ok, %{state: "MERGED"}} ->
        finish(issue, "done", "Pull request merged")

      {:ok, %{state: "CLOSED"}} ->
        finish(issue, "cancelled", "Pull request closed without merging")

      _ ->
        :ok
    end
  end

  def check(%Issue{project: project} = issue) do
    case GitHub.impl().get_issue(project.repo, issue.number) do
      {:ok, %{state: "CLOSED"}} ->
        finish(issue, "cancelled", "The issue was closed")

      {:ok, gh_issue} ->
        comments = new_comments(issue, gh_issue.comments ++ pr_comments(issue))
        react(issue, Enum.flat_map(comments, &commands/1), comments)

      {:error, reason} ->
        Logger.warning("Could not read #{project.repo}##{issue.number}: #{inspect(reason)}")
    end
  end

  defp react(_issue, _commands, []), do: :ok

  defp react(issue, commands, _comments) do
    cond do
      "stop" in commands ->
        finish(issue, "cancelled", "Stopped with /factory stop")

      issue.state == "awaiting_answers" ->
        resume(issue, fn -> Pipeline.transition(issue, "planning", %{}, "Answers received") end)

      issue.state == "awaiting_plan_approval" and "approve" in commands ->
        resume(issue, fn -> Pipeline.approve(issue) end)

      issue.state == "awaiting_plan_approval" ->
        resume(issue, fn ->
          Pipeline.transition(issue, "planning", %{}, "Feedback on the plan received")
        end)

      "approve" in commands or "retry" in commands ->
        resume(issue, fn -> Pipeline.approve(issue) end)

      true ->
        # A comment that is not a command, while held: remember we saw it.
        Pipeline.update_issue(issue, %{comments_seen_at: DateTime.utc_now()})
    end
  end

  @doc "Stops work on an issue for good, from the UI."
  def stop(%Issue{} = issue, actor \\ "a person"),
    do: finish(Repo.preload(issue, :project), "cancelled", "Stopped by #{actor}")

  @doc """
  A person asks for changes to the plan from the UI. Their feedback is posted on
  the issue unsigned, as their own comment, so the Planner reads it as a
  maintainer's decision; the plan is then revised right away.
  """
  def request_plan_changes(issue, feedback, actor \\ nil)

  def request_plan_changes(%Issue{state: "awaiting_plan_approval"} = issue, feedback, actor) do
    issue = Repo.preload(issue, :project)
    # Everyone posts through the same GitHub account, so the comment says who wrote it.
    body =
      if actor, do: "#{feedback}\n\n_Sent from Software Factory by #{actor}._", else: feedback

    with :ok <- GitHub.impl().comment(issue.project.repo, issue.number, body) do
      note =
        if actor,
          do: "Changes to the plan requested by #{actor}",
          else: "Feedback on the plan received"

      Pipeline.transition(issue, "planning", %{}, note)
    end
  end

  def request_plan_changes(%Issue{}, _feedback, _actor), do: {:error, :not_waiting_for_approval}

  defp resume(issue, fun) do
    GitHub.impl().set_label(issue.project.repo, issue.number, Stages.needs_human_label(), false)
    fun.()
  end

  defp finish(issue, state, note) do
    project = issue.project
    Workspace.impl().cleanup(project, issue)
    GitHub.impl().set_label(project.repo, issue.number, Stages.needs_human_label(), false)
    Pipeline.transition(issue, state, %{}, note)
  end

  # Comments a person with authority wrote since the issue started waiting.
  defp new_comments(issue, comments) do
    allowed = Project.allowed_logins(issue.project)

    Enum.filter(comments, fn comment ->
      not GitHub.from_factory?(comment) and String.downcase(comment.author) in allowed and
        (is_nil(issue.comments_seen_at) or
           DateTime.compare(comment.created_at, issue.comments_seen_at) == :gt)
    end)
  end

  defp pr_comments(%Issue{pr_number: nil}), do: []

  defp pr_comments(%Issue{pr_number: number, project: project}) do
    case GitHub.impl().get_issue(project.repo, number) do
      {:ok, pr} -> pr.comments
      _ -> []
    end
  end

  @doc "The `/factory <command>` lines in a comment."
  def commands(%{body: body}) do
    for [_, command] <- Regex.scan(~r{^\s*/factory\s+(approve|retry|stop)\b}mi, body),
        do: String.downcase(command)
  end

  # An issue in an active state always has a job. If it does not (the factory
  # was killed mid-run), surface it as failed so a person can retry it.
  defp reconcile(issue) do
    stale? = DateTime.diff(DateTime.utc_now(), issue.state_entered_at, :second) > 120

    job? =
      Repo.exists?(
        from j in Oban.Job,
          where: j.worker == "Factory.Workers.StageWorker",
          where: j.state in ["available", "scheduled", "executing", "retryable"],
          where: fragment("(?->>'issue_id')::bigint = ?", j.args, ^issue.id)
      )

    if stale? and not job?,
      do: Pipeline.fail(issue, "The run was interrupted. Retry to run this stage again.")
  end
end
