defmodule Factory.Pipeline do
  @moduledoc """
  State and history of the issues in the factory.

  Every state change goes through `transition/4`, which keeps the `transitions`
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
  """
  def transition(%Issue{} = issue, state, attrs \\ %{}, note \\ nil) do
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

    {:ok, issue} =
      Repo.transaction(fn ->
        from(t in Transition, where: t.issue_id == ^issue.id and is_nil(t.left_at))
        |> Repo.update_all(set: [left_at: now])

        Repo.insert!(%Transition{issue_id: issue.id, state: state, note: note, entered_at: now})
        issue |> Ecto.Changeset.change(attrs) |> Repo.update!()
      end)

    if state in Issue.active_states() do
      %{issue_id: issue.id, state: state} |> Factory.Workers.StageWorker.new() |> Oban.insert!()
    end

    broadcast(issue.id)
    {:ok, issue}
  end

  def update_issue(%Issue{} = issue, attrs) do
    issue = issue |> Ecto.Changeset.change(Map.new(attrs)) |> Repo.update!()
    broadcast(issue.id)
    issue
  end

  ## Stage runs

  def start_run(%Issue{} = issue, attrs) do
    run =
      Repo.insert!(
        struct!(
          StageRun,
          Map.merge(Map.new(attrs), %{issue_id: issue.id, started_at: DateTime.utc_now()})
        )
      )

    broadcast(issue.id)
    run
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
  def approve(%Issue{state: "awaiting_plan_approval"} = issue) do
    transition(issue, "developing", %{}, "Plan approved by a person")
  end

  def approve(%Issue{state: state, resume_state: resume} = issue)
      when state in ["needs_human", "failed"] and is_binary(resume) do
    attrs =
      case issue.hold_reason do
        "plan_rounds_exhausted" -> %{plan_round_limit: issue.plan_round + 1}
        "pr_rounds_exhausted" -> %{pr_round_limit: issue.pr_round + 1}
        _ -> %{}
      end

    attrs = Map.merge(attrs, %{hold_reason: nil, hold_detail: nil, resume_state: nil})
    transition(issue, resume, attrs, "Continued by a person")
  end

  def approve(%Issue{}), do: {:error, :not_waiting_for_approval}

  def cancel(%Issue{} = issue, note \\ "Stopped by a person") do
    if Issue.terminal?(issue), do: {:ok, issue}, else: transition(issue, "cancelled", %{}, note)
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
