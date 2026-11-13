defmodule Factory.Pipeline do
  @moduledoc """
  State and history of the issues in the factory.

  Every state change goes through `transition/5`, which keeps the `transitions`
  history (used for the time spent per stage), notifies the UI and, when the new
  state is one an agent works on, enqueues the job that runs it.
  """
  import Ecto.Query
  alias Factory.Pipeline.{Issue, StageRun, Transition}
  alias Factory.Projects.Project
  alias Factory.Repo

  @topic "pipeline"

  def subscribe, do: Phoenix.PubSub.subscribe(Factory.PubSub, @topic)

  defp broadcast(issue_id) do
    Phoenix.PubSub.broadcast(Factory.PubSub, @topic, {:issue_updated, issue_id})
  end

  ## Reading

  def list_issues do
    costs =
      from r in StageRun,
        group_by: r.issue_id,
        select: %{issue_id: r.issue_id, cost: sum(r.cost_usd)}

    Repo.all(
      from i in Issue,
        left_join: c in subquery(costs),
        on: c.issue_id == i.id,
        order_by: [desc: i.state_entered_at],
        preload: [:project],
        select_merge: %{cost_usd: c.cost}
    )
  end

  @doc "The most recently active issues with their state history and runs, for the dashboard."
  def overview(limit \\ 100) do
    issues = Enum.take(list_issues(), limit)
    ids = Enum.map(issues, & &1.id)

    transitions =
      Repo.all(
        from t in Transition, where: t.issue_id in ^ids, order_by: [asc: t.entered_at, asc: t.id]
      )
      |> Enum.group_by(& &1.issue_id)

    runs =
      Repo.all(
        from r in StageRun, where: r.issue_id in ^ids, order_by: [asc: r.started_at, asc: r.id]
      )
      |> Enum.group_by(& &1.issue_id)

    for issue <- issues do
      %{
        issue: issue,
        transitions: Map.get(transitions, issue.id, []),
        runs: Map.get(runs, issue.id, [])
      }
    end
  end

  @doc """
  Seconds an issue spent in the given states, or nil if it never entered any.
  A state it is still in runs until `now`.
  """
  def time_in(transitions, states, now) do
    case for t <- transitions,
             t.state in states,
             do: DateTime.diff(t.left_at || now, t.entered_at) do
      [] -> nil
      seconds -> seconds |> Enum.sum() |> max(0)
    end
  end

  def list_by_state(states) do
    Repo.all(from i in Issue, where: i.state in ^states, preload: [:project], order_by: i.id)
  end

  def get_issue!(id), do: Issue |> Repo.get!(id) |> Repo.preload(:project)

  def get_issue_by_number(%Project{id: project_id}, number) do
    Repo.get_by(Issue, project_id: project_id, number: number)
  end

  def tracked_numbers(%Project{id: project_id}) do
    Repo.all(from i in Issue, where: i.project_id == ^project_id, select: i.number)
  end

  def list_transitions(%Issue{id: id}) do
    Repo.all(
      from t in Transition, where: t.issue_id == ^id, order_by: [asc: t.entered_at, asc: t.id]
    )
  end

  def list_runs(%Issue{id: id}) do
    Repo.all(
      from r in StageRun, where: r.issue_id == ^id, order_by: [asc: r.started_at, asc: r.id]
    )
  end

  @doc "The most recent finished run of a stage, used to hand review findings to the next agent."
  def last_run(%Issue{id: id}, stage) do
    Repo.one(
      from r in StageRun,
        where: r.issue_id == ^id and r.stage == ^stage and r.status == "ok",
        order_by: [desc: r.started_at, desc: r.id],
        limit: 1
    )
  end

  ## Tracking and transitions

  def track_issue(%Project{} = project, %{number: number, title: title} = gh_issue) do
    now = DateTime.utc_now()

    issue = %Issue{
      project_id: project.id,
      number: number,
      title: String.slice(title, 0, 250),
      url: gh_issue[:url],
      body_hash: hash(gh_issue[:body]),
      state: "queued",
      state_entered_at: now,
      plan_round_limit: project.max_plan_rounds,
      pr_round_limit: project.max_pr_rounds,
      branch: "factory/issue-#{number}"
    }

    with {:ok, issue} <-
           Repo.insert(issue, on_conflict: :nothing, conflict_target: [:project_id, :number]),
         %Issue{id: id} when not is_nil(id) <- issue do
      Repo.insert!(%Transition{issue_id: id, state: "queued", entered_at: now})
      transition(issue, "planning", %{}, "Picked up from GitHub")
    else
      _already_tracked -> :ignored
    end
  end

  @doc """
  Moves an issue to `state`, applying `attrs` to it in the same transaction.

  The issue's row is locked first, and every decision is made on it rather than
  on the `issue` given: an issue that is already `done` or `cancelled` is never
  moved again (a stage finishing late cannot undo a cancellation), and the job
  of the new state is enqueued in the same transaction.

  Options:
    * `:unchanged_since` — an issue read earlier; if its wait (`state_entered_at`)
      or its `pr_comments_seen_at` changed since, nothing is written and
      `{:error, :stale}` is returned.
    * `:seen_until` — moves `pr_comments_seen_at` forward to this time (never back).
  """
  def transition(%Issue{} = issue, state, attrs \\ %{}, note \\ nil, opts \\ []) do
    Repo.transaction(fn ->
      row = lock!(issue.id)
      {row, write_transition(row, state, attrs, note, opts)}
    end)
    |> after_commit(issue)
  end

  defp after_commit({:ok, {row, updated}}, issue) do
    updated = %{updated | project: issue.project}
    Factory.Pipeline.GitHubStatus.sync(row, updated)
    broadcast(updated.id)
    {:ok, updated}
  end

  defp after_commit({:error, reason}, _issue), do: {:error, reason}

  # Every transaction that writes transitions locks the issue's row first, so
  # they are serialized in one order and never deadlock.
  defp lock!(id), do: Repo.one!(from i in Issue, where: i.id == ^id, lock: "FOR UPDATE")

  defp write_transition(row, state, attrs, note, opts) do
    cond do
      Issue.terminal?(row) ->
        row

      stale?(row, opts[:unchanged_since]) ->
        Repo.rollback(:stale)

      true ->
        now = DateTime.utc_now()

        attrs =
          attrs
          |> Map.new()
          |> Map.merge(%{state: state, state_entered_at: now})
          |> then(fn attrs ->
            # Comments older than the moment we start waiting were already seen by an agent.
            if state in Issue.waiting_states(),
              do: Map.put_new(attrs, :comments_seen_at, now),
              else: attrs
          end)
          |> then(fn attrs ->
            case opts[:seen_until] do
              nil -> attrs
              cut -> Map.put(attrs, :pr_comments_seen_at, latest(row.pr_comments_seen_at, cut))
            end
          end)

        from(t in Transition, where: t.issue_id == ^row.id and is_nil(t.left_at))
        |> Repo.update_all(set: [left_at: now])

        Repo.insert!(%Transition{
          issue_id: row.id,
          state: state,
          note: note,
          entered_at: now,
          hold_reason: if(state == "needs_human", do: attrs[:hold_reason])
        })

        updated = row |> Ecto.Changeset.change(attrs) |> Repo.update!()

        if state in Issue.active_states() do
          %{issue_id: row.id, state: state} |> Factory.Workers.StageWorker.new() |> Oban.insert!()
        end

        updated
    end
  end

  # Whether the issue moved on since `snapshot` was read.
  defp stale?(_row, nil), do: false

  defp stale?(row, %Issue{} = snapshot) do
    not (same_time?(row.state_entered_at, snapshot.state_entered_at) and
           same_time?(row.pr_comments_seen_at, snapshot.pr_comments_seen_at))
  end

  defp same_time?(nil, nil), do: true
  defp same_time?(nil, _), do: false
  defp same_time?(_, nil), do: false
  defp same_time?(a, b), do: DateTime.compare(a, b) == :eq

  defp latest(nil, at), do: at
  defp latest(current, at), do: if(DateTime.compare(at, current) == :gt, do: at, else: current)

  @doc """
  Records that the comments on the issue and its pull request up to `cut` were
  handled, if the issue is still in the wait `issue` was read in. The mark never
  moves back.
  """
  def mark_pr_comments_seen(%Issue{} = issue, cut) do
    Repo.transaction(fn ->
      row = lock!(issue.id)
      if stale?(row, issue), do: Repo.rollback(:stale)

      row
      |> Ecto.Changeset.change(pr_comments_seen_at: latest(row.pr_comments_seen_at, cut))
      |> Repo.update!()
    end)
    |> case do
      {:ok, updated} ->
        broadcast(updated.id)
        {:ok, %{updated | project: issue.project}}

      error ->
        error
    end
  end

  @doc """
  Whether the issue is done or cancelled. It waits for a cancellation that is
  being written, so an effect checked with it never runs after one.
  """
  def stopped?(%Issue{id: id}) do
    {:ok, state} =
      Repo.transaction(fn ->
        Repo.one!(from i in Issue, where: i.id == ^id, select: i.state, lock: "FOR SHARE")
      end)

    state in Issue.terminal_states()
  end

  @doc """
  The periods the issue spent waiting with its pull request open for changes:
  `ready_to_merge`, and `needs_human` after the review rounds ran out.
  `left_at` is nil for the current one.
  """
  def pr_waiting_periods(%Issue{id: id}) do
    Repo.all(
      from t in Transition,
        where: t.issue_id == ^id,
        where:
          t.state == "ready_to_merge" or
            (t.state == "needs_human" and t.hold_reason == "pr_rounds_exhausted"),
        order_by: [asc: t.entered_at, asc: t.id],
        select: {t.entered_at, t.left_at}
    )
  end

  @doc """
  A person asks for changes to the pull request: the issue goes back to
  `developing` with their feedback, as one atomic decision on the stored issue.

  It is refused with `{:error, :not_accepting_pr_changes}` unless the issue is
  waiting in one of the states of `Issue.accepts_pr_changes?/1` — so of two
  requests at once only the first wins, and nothing is ever added to a round
  that is already open. Rounds asked by a person do not use up automatic ones.

  Options, besides those of `transition/5`:
    * `:before_commit` — called with the locked issue before anything is
      written; it may only read. `{:ok, _}` lets the request go on; `{:error,
      reason}` rolls it back.
    * `:jobs` — Oban job changesets inserted in the same transaction.
  """
  def request_pr_changes(%Issue{} = issue, feedback, note, opts \\ []) do
    Repo.transaction(fn ->
      row = lock!(issue.id)
      if not Issue.accepts_pr_changes?(row), do: Repo.rollback(:not_accepting_pr_changes)

      case (opts[:before_commit] || fn _ -> {:ok, row} end).(row) do
        {:ok, _} -> :ok
        {:error, reason} -> Repo.rollback(reason)
      end

      limit =
        if row.state == "ready_to_merge", do: row.pr_round_limit + 1, else: row.pr_round + 1

      attrs = %{
        pr_round_limit: limit,
        pr_feedback: join_feedback([row.pr_feedback, feedback]),
        hold_reason: nil,
        hold_detail: nil,
        resume_state: nil
      }

      updated = write_transition(row, "developing", attrs, note, opts)
      for job <- opts[:jobs] || [], do: Oban.insert!(job)
      {row, updated}
    end)
    |> after_commit(issue)
  end

  @doc "Joins pieces of feedback, oldest first, leaving out the missing ones."
  def join_feedback(pieces) do
    case Enum.reject(pieces, &(&1 in [nil, ""])) do
      [] -> nil
      pieces -> Enum.join(pieces, "\n\n---\n\n")
    end
  end

  def update_issue(%Issue{} = issue, attrs) do
    issue = issue |> Ecto.Changeset.change(Map.new(attrs)) |> Repo.update!()
    broadcast(issue.id)
    issue
  end

  ## Stage runs

  @doc """
  Records that an agent or a check starts, unless the issue was stopped.

  The issue's row is read `FOR SHARE`, so this and a cancellation are
  serialized: if the cancellation commits first, `{:error, :stopped}` and
  nothing starts; otherwise the run counts as started and the cancellation
  waits for it to be recorded. Call the agent or check right after.
  """
  def authorize_run(%Issue{id: id}, attrs) do
    Repo.transaction(fn ->
      state = Repo.one!(from i in Issue, where: i.id == ^id, select: i.state, lock: "FOR SHARE")
      if state in Issue.terminal_states(), do: Repo.rollback(:stopped)

      Repo.insert!(
        struct!(
          StageRun,
          Map.merge(Map.new(attrs), %{issue_id: id, started_at: DateTime.utc_now()})
        )
      )
    end)
    |> case do
      {:ok, run} ->
        broadcast(id)
        {:ok, run}

      error ->
        error
    end
  end

  def finish_run(%StageRun{} = run, status, attrs \\ %{}) do
    attrs = attrs |> Map.new() |> Map.merge(%{status: status, finished_at: DateTime.utc_now()})
    run = run |> Ecto.Changeset.change(attrs) |> Repo.update!()
    broadcast(run.issue_id)
    run
  end

  @doc "Marks runs left as running by a crashed job as failed."
  def close_dangling_runs(%Issue{id: id}) do
    from(r in StageRun, where: r.issue_id == ^id and r.status == "running")
    |> Repo.update_all(
      set: [status: "failed", finished_at: DateTime.utc_now(), summary: "Interrupted"]
    )
  end

  ## Human decisions

  @doc """
  A person lets the issue continue: approves the plan, grants one more review
  round after the limit was reached, or retries after a failure.
  """
  def approve(issue, actor \\ "a person", opts \\ [])

  def approve(%Issue{state: "awaiting_plan_approval"} = issue, actor, opts) do
    transition(issue, "developing", %{}, "Plan approved by #{actor}", opts)
  end

  def approve(%Issue{state: state, resume_state: resume} = issue, actor, opts)
      when state in ["needs_human", "failed"] and is_binary(resume) do
    attrs =
      case issue.hold_reason do
        "plan_rounds_exhausted" -> %{plan_round_limit: issue.plan_round + 1}
        "pr_rounds_exhausted" -> %{pr_round_limit: issue.pr_round + 1}
        _ -> %{}
      end

    attrs = Map.merge(attrs, %{hold_reason: nil, hold_detail: nil, resume_state: nil})
    transition(issue, resume, attrs, "Continued by #{actor}", opts)
  end

  def approve(%Issue{}, _actor, _opts), do: {:error, :not_waiting_for_approval}

  @doc "Stops the issue for good. Takes the options of `transition/5`."
  def cancel(%Issue{} = issue, note \\ "Stopped by a person", opts \\ []) do
    transition(issue, "cancelled", %{}, note, opts)
  end

  @doc "Parks the issue until a person decides. `resume` is the state `approve/1` goes back to."
  def hold(%Issue{} = issue, reason, detail, resume) do
    transition(
      issue,
      "needs_human",
      %{hold_reason: reason, hold_detail: detail, resume_state: resume},
      detail
    )
  end

  def fail(%Issue{} = issue, detail) do
    detail = String.slice(to_string(detail), 0, 4000)
    resume = if issue.state in Issue.active_states(), do: issue.state, else: issue.resume_state
    close_dangling_runs(issue)

    transition(
      issue,
      "failed",
      %{hold_reason: "error", hold_detail: detail, resume_state: resume},
      detail
    )
  end

  def hash(nil), do: hash("")
  def hash(text), do: :crypto.hash(:sha256, text) |> Base.encode16(case: :lower)
end
