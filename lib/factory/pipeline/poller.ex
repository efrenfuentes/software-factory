defmodule Factory.Pipeline.Poller do
  @moduledoc """
  Periodic look at GitHub: picks up issues carrying the project's trigger label
  and, for issues waiting on a person, reacts to their comments and to the PR
  being merged or closed.

  Only people who can label issues can start work, and only comments from the
  project's allowed users are acted on. Commands are `/factory approve`,
  `/factory retry` and `/factory stop`.

  While the pull request waits for a person — `ready_to_merge`, or `needs_human`
  after the automatic review rounds ran out — any other comment from an allowed
  user, on the issue, on the pull request, as the text of a submitted review or
  on a line of the diff, sends the issue back to `developing` with that
  feedback (`Pipeline.request_pr_changes/4`). Those comments are read with a
  cursor of their own, `pr_comments_seen_at`: only what was written while the
  issue waited in those states counts, and each pass decides on the comments up
  to a cut taken before its first read, writing its effect only if the issue
  did not move in the meantime. A failed read makes the pass do nothing.
  """
  import Ecto.Query
  require Logger
  alias Factory.{GitHub, Pipeline, Projects, Repo, Workspace}
  alias Factory.Pipeline.{Issue, Stages}
  alias Factory.Projects.Project
  alias Factory.Workers.CommentWorker

  # Margin for clock skew between the factory and GitHub.
  @settle_seconds 10
  @panel_mark "<!-- software-factory:panel "

  @doc "One look at GitHub. `now:` sets the time the pass reads at (for tests)."
  def poll(opts \\ []) do
    now = opts[:now] || DateTime.utc_now()

    for project <- Projects.list_enabled(), do: discover(project)

    for issue <- Pipeline.list_by_state(Issue.waiting_states()),
        issue.project.enabled,
        do: safely(issue, &check(&1, now))

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

  def check(issue, now \\ DateTime.utc_now())

  def check(%Issue{state: "ready_to_merge", project: project} = issue, now) do
    cut = DateTime.add(now, -@settle_seconds)

    case GitHub.impl().get_pr(project.repo, issue.pr_number) do
      {:ok, %{state: "MERGED"}} ->
        finish(issue, "done", "Pull request merged")

      {:ok, %{state: "CLOSED"}} ->
        finish(issue, "cancelled", "Pull request closed without merging")

      {:ok, _open} ->
        with {:ok, comments} <- pr_change_comments(issue, cut),
             do: react_pr(issue, comments, cut, true)

      {:error, reason} ->
        Logger.warning("Could not read #{project.repo}##{issue.pr_number}: #{inspect(reason)}")
    end
  end

  def check(%Issue{project: project} = issue, now) do
    cut = DateTime.add(now, -@settle_seconds)

    case GitHub.impl().get_issue(project.repo, issue.number) do
      {:ok, %{state: "CLOSED"}} ->
        finish(issue, "cancelled", "The issue was closed")

      {:ok, gh_issue} ->
        if Issue.accepts_pr_changes?(issue) do
          check_pr(issue, gh_issue, cut)
        else
          comments = new_comments(issue, gh_issue.comments ++ pr_comments(issue))
          react(issue, Enum.flat_map(comments, &commands/1), comments)
        end

      {:error, reason} ->
        Logger.warning("Could not read #{project.repo}##{issue.number}: #{inspect(reason)}")
    end
  end

  # Held after the review rounds ran out: comments ask for changes while the
  # pull request is open; commands work as in any other hold.
  defp check_pr(%Issue{project: project} = issue, gh_issue, cut) do
    case GitHub.impl().get_pr(project.repo, issue.pr_number) do
      {:ok, pr} ->
        with {:ok, comments} <- pr_change_comments(issue, cut, gh_issue),
             do: react_pr(issue, comments, cut, pr.state == "OPEN")

      {:error, reason} ->
        Logger.warning("Could not read #{project.repo}##{issue.pr_number}: #{inspect(reason)}")
    end
  end

  # Everything written on the issue, the pull request and its reviews that is
  # still pending, or `:error` if any of it could not be read.
  defp pr_change_comments(%Issue{project: project} = issue, cut, gh_issue \\ nil) do
    gh = GitHub.impl()

    with {:ok, gh_issue} <-
           if(gh_issue, do: {:ok, gh_issue}, else: gh.get_issue(project.repo, issue.number)),
         {:ok, pr} <- gh.get_issue(project.repo, issue.pr_number),
         {:ok, reviews} <- gh.pr_review_comments(project.repo, issue.pr_number) do
      comments =
        Enum.map(gh_issue.comments, &Map.put(&1, :on, :issue)) ++
          Enum.map(pr.comments, &Map.put(&1, :on, :pull_request)) ++
          Enum.map(reviews, &Map.put(&1, :on, :review))

      {:ok, pending(issue, comments, cut)}
    else
      {:error, reason} ->
        Logger.warning(
          "Could not read the comments of #{project.repo}##{issue.number}: #{inspect(reason)}"
        )

        :error
    end
  end

  # Comments from allowed users, not written by the factory or the panel, after
  # the cursor and up to the cut, and written while the issue waited with its
  # pull request open for changes. `current?` marks those of the current wait.
  defp pending(issue, comments, cut) do
    allowed = Project.allowed_logins(issue.project)
    periods = Pipeline.pr_waiting_periods(issue)
    current_from = DateTime.add(issue.state_entered_at, -@settle_seconds)

    comments
    |> Enum.filter(fn comment ->
      at = comment.created_at

      not GitHub.from_factory?(comment) and not panel_comment?(comment) and
        String.downcase(comment.author) in allowed and
        (is_nil(issue.pr_comments_seen_at) or
           DateTime.compare(at, issue.pr_comments_seen_at) == :gt) and
        DateTime.compare(at, cut) != :gt and
        Enum.any?(periods, &within?(at, &1))
    end)
    |> Enum.map(&Map.put(&1, :current?, DateTime.compare(&1.created_at, current_from) != :lt))
    |> Enum.sort_by(& &1.created_at, DateTime)
  end

  defp within?(at, {entered_at, left_at}) do
    DateTime.compare(at, DateTime.add(entered_at, -@settle_seconds)) != :lt and
      (is_nil(left_at) or
         DateTime.compare(at, DateTime.add(left_at, @settle_seconds)) != :gt)
  end

  defp react_pr(_issue, [], _cut, _pr_open?), do: :ok

  defp react_pr(issue, comments, cut, pr_open?) do
    plain = Enum.filter(comments, &(commands(&1) == []))
    current = comments |> Enum.filter(& &1.current?) |> Enum.flat_map(&commands/1)
    # Written only if the issue is still in the wait this pass read it in.
    guard = [unchanged_since: issue, seen_until: cut]

    cond do
      "stop" in Enum.flat_map(comments, &commands/1) ->
        with {:ok, _} = ok <- Pipeline.cancel(issue, "Stopped with /factory stop", guard) do
          Workspace.impl().cleanup(issue.project, issue)
          remove_needs_human(issue)
          ok
        end

      pr_open? and plain != [] ->
        pr_changes(issue, plain, guard)

      issue.state == "needs_human" and ("approve" in current or "retry" in current) ->
        with {:ok, _} = ok <- Pipeline.approve(issue, "a person", guard) do
          remove_needs_human(issue)
          ok
        end

      true ->
        Pipeline.mark_pr_comments_seen(issue, cut)
    end
  end

  defp pr_changes(issue, comments, guard) do
    authors = comments |> Enum.map(&"@#{&1.author}") |> Enum.uniq() |> Enum.join(", ")

    with {:ok, _} = ok <-
           Pipeline.request_pr_changes(
             issue,
             feedback_text(comments),
             "Changes to the pull request requested by #{authors}",
             guard
           ) do
      remove_needs_human(issue)

      GitHub.post(
        issue.project.repo,
        issue.pr_number,
        "**Changes requested by #{authors}.** The Developer is working on them; " <>
          "the pull request will be reviewed again once they are pushed."
      )

      ok
    end
  end

  @doc "Comments as feedback for the agents, oldest first, each with its author and where it was written."
  def feedback_text(comments) do
    Enum.map_join(comments, "\n\n---\n\n", fn comment ->
      "[maintainer @#{comment.author}, #{origin(comment)}]\n#{comment.body}"
    end)
  end

  defp origin(%{on: :issue}), do: "on the issue"
  defp origin(%{on: :pull_request}), do: "on the pull request"
  defp origin(%{on: :review, path: nil}), do: "review of the pull request"
  defp origin(%{on: :review, path: path, line: nil}), do: "review comment on #{path}"
  defp origin(%{on: :review, path: path, line: line}), do: "review comment on #{path}:#{line}"

  defp remove_needs_human(issue) do
    GitHub.impl().set_label(issue.project.repo, issue.number, Stages.needs_human_label(), false)
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
    body = if actor, do: "#{feedback}\n\n" <> panel_signature(actor), else: feedback

    with :ok <- GitHub.impl().comment(issue.project.repo, issue.number, body) do
      note =
        if actor,
          do: "Changes to the plan requested by #{actor}",
          else: "Feedback on the plan received"

      Pipeline.transition(issue, "planning", %{}, note)
    end
  end

  def request_plan_changes(%Issue{}, _feedback, _actor), do: {:error, :not_waiting_for_approval}

  @doc """
  A person asks for changes to the pull request from the UI. The issue goes back
  to `developing` with their feedback only if, on the stored issue, the pull
  request is waiting for changes and still open; their comment is then posted on
  the pull request by a job enqueued with that change, signed with their name
  and a hidden mark so the factory does not read it again as feedback.
  """
  def request_pr_changes(%Issue{} = issue, feedback, actor) do
    issue = Pipeline.get_issue!(issue.id)

    if Issue.accepts_pr_changes?(issue) do
      repo = issue.project.repo

      result =
        Pipeline.request_pr_changes(
          issue,
          "[maintainer #{actor}, from Software Factory]\n#{feedback}",
          "Changes to the pull request requested by #{actor}",
          before_commit: fn row ->
            case GitHub.impl().get_pr(repo, row.pr_number) do
              {:ok, %{state: "OPEN"}} -> {:ok, row}
              {:ok, _merged_or_closed} -> {:error, :pr_not_open}
              {:error, reason} -> {:error, reason}
            end
          end,
          jobs: [
            CommentWorker.new_comment(
              issue,
              issue.pr_number,
              "#{feedback}\n\n" <> panel_signature(actor)
            )
          ]
        )

      with {:ok, _} <- result, do: remove_needs_human(issue)
      result
    else
      {:error, :not_accepting_pr_changes}
    end
  end

  @doc "How a comment posted from the panel says who wrote it."
  def panel_signature(actor), do: "_Sent from Software Factory by #{actor}._"

  @doc "The hidden mark of a comment posted from the panel; `token` tells each one apart."
  def panel_mark(token), do: "#{@panel_mark}#{token} -->"

  @doc "Whether a comment was posted from the panel (its feedback is already recorded)."
  def panel_comment?(%{body: body}), do: String.contains?(body, @panel_mark)

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
