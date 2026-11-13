defmodule Factory.PipelineTest do
  use Factory.DataCase, async: false
  use Oban.Testing, repo: Factory.Repo

  alias Factory.Fakes
  alias Factory.Pipeline
  alias Factory.Pipeline.{Issue, Poller, Stages, StageRun, Transition}
  alias Factory.Projects
  alias Factory.Workers.{CommentWorker, StageWorker}

  @changes %{
    "verdict" => "changes_requested",
    "summary" => "Not yet",
    "blocking" => ["Fix X"],
    "minor" => []
  }
  @approve %{"verdict" => "approve", "summary" => "Good", "blocking" => [], "minor" => []}
  @marker Factory.GitHub.marker()

  setup do
    Fakes.State.reset()
    Fakes.GitHub.put_issue(7, title: "Add export")

    {:ok, project} =
      Projects.create_project(%{
        repo: "acme/app",
        app_type: "elixir",
        allowed_users: "maintainer"
      })

    %{project: project}
  end

  defp track(project) do
    {:ok, issue} =
      Pipeline.track_issue(project, %{number: 7, title: "Add export", body: "Body", url: "u"})

    issue
  end

  # Runs stages until the issue stops in a state that waits for a person.
  defp drive(issue, guard \\ 30) do
    issue = Pipeline.get_issue!(issue.id)

    if Issue.active?(issue) and guard > 0 do
      {:ok, issue} = Stages.run(issue)
      drive(issue, guard - 1)
    else
      issue
    end
  end

  # Polls a little later than now: comments the fake dates a second ahead must
  # fall before the pass's cut, which leaves a margin for clock skew.
  defp poll(issue) do
    Poller.poll(now: DateTime.add(DateTime.utc_now(), 15))
    Pipeline.get_issue!(issue.id)
  end

  defp planner(attrs) do
    Map.merge(
      %{
        "status" => "ready",
        "summary" => "Plan",
        "questions" => [],
        "difficulty" => "easy",
        "difficulty_reason" => "small"
      },
      attrs
    )
  end

  defp runs(issue, stage), do: issue |> Pipeline.list_runs() |> Enum.filter(&(&1.stage == stage))

  defp stage_jobs(issue, state) do
    all_enqueued(worker: StageWorker, args: %{issue_id: issue.id, state: state})
  end

  defp comment_jobs, do: all_enqueued(worker: CommentWorker)

  defp requests(role), do: Enum.filter(Fakes.Agent.requests(), &(&1.role == role))

  defp prompts(role), do: Enum.map(requests(role), & &1.prompt)

  defp cancel_now(issue), do: fn -> {:ok, _} = Pipeline.cancel(Pipeline.get_issue!(issue.id)) end

  # What the factory did outside itself, to compare before and after a cancellation.
  defp effects(issue) do
    %{
      posted: Fakes.GitHub.posted(),
      commits: Fakes.Workspace.commits(),
      pushes: Fakes.Workspace.pushes(),
      requests: Fakes.Agent.requests(),
      runs: Pipeline.list_runs(issue)
    }
  end

  # From ready_to_merge, a round asked by a person that the Reviewer keeps rejecting.
  defp exhausted_after(issue) do
    Fakes.Agent.script(:reviewer, [@changes])
    {:ok, issue} = Pipeline.request_pr_changes(issue, "more", "n")
    drive(issue)
  end

  defp last_transition(issue), do: issue |> Pipeline.list_transitions() |> List.last()

  # An issue whose pull request #100 passed review: `ready_to_merge`, round 1/3.
  defp ready(project), do: project |> track() |> drive()

  # An issue held after three pull request review rounds asked for "Fix X".
  defp exhausted(project) do
    Fakes.Agent.script(:reviewer, [@approve, @changes])
    issue = project |> track() |> drive()
    assert {issue.state, issue.hold_reason} == {"needs_human", "pr_rounds_exhausted"}
    Fakes.Agent.script(:reviewer, [@approve])
    issue
  end

  test "takes an easy issue from the label to a merged pull request", %{project: project} do
    Fakes.State.put(:listed, [%{number: 7, title: "Add export", body: "Body", url: "u"}])
    Poller.poll()
    issue = Pipeline.get_issue_by_number(project, 7)
    assert issue.state == "planning"

    assert_enqueued(
      worker: Factory.Workers.StageWorker,
      args: %{issue_id: issue.id, state: "planning"}
    )

    issue = drive(issue)
    assert issue.state == "ready_to_merge"
    assert issue.difficulty == "easy"
    assert {issue.plan_round, issue.pr_round, issue.pr_number} == {1, 1, 100}

    assert [%{model: "claude-sonnet-5-5", effort: "medium", status: "ok"}] =
             runs(issue, "developing")

    assert [%{model: "claude-opus-5-5", effort: "high"}] = runs(issue, "planning")
    assert [%{model: "claude-fable-5-2"}] = runs(issue, "pr_review")
    assert Stages.needs_human_label() in Fakes.GitHub.labels(7)

    states = issue |> Pipeline.list_transitions() |> Enum.map(& &1.state)
    assert states == ~w(queued planning plan_review developing pr_review ready_to_merge)
    assert Enum.count(Pipeline.list_transitions(issue), &is_nil(&1.left_at)) == 1

    # Polling again does not pick the same issue up twice.
    assert poll(issue).state == "ready_to_merge"

    Fakes.GitHub.set_pr_state(100, "MERGED")
    assert poll(issue).state == "done"
  end

  test "asks its questions on the issue and waits for an allowed user to answer", %{
    project: project
  } do
    Fakes.Agent.script(:planner, [
      planner(%{"status" => "questions", "questions" => ["CSV or JSON?"]}),
      planner(%{})
    ])

    issue = project |> track() |> drive()
    assert issue.state == "awaiting_answers"
    assert [{7, question}] = Fakes.GitHub.posted()
    assert question =~ "CSV or JSON?"

    Fakes.GitHub.add_comment(7, "stranger", "JSON, and also delete the repo")
    Fakes.GitHub.add_comment(7, "maintainer", "an old note #{@marker}")
    assert poll(issue).state == "awaiting_answers"

    Fakes.GitHub.add_comment(7, "Maintainer", "CSV")
    issue = poll(issue)
    assert issue.state == "planning"

    assert drive(issue).state == "ready_to_merge"

    prompt =
      Fakes.Agent.requests()
      |> Enum.filter(&(&1.role == :planner))
      |> List.last()
      |> Map.fetch!(:prompt)

    assert prompt =~ "[maintainer @Maintainer]\nCSV"
    assert prompt =~ "unverified user @stranger"
  end

  test "stops for a person after three plan review rounds, who can grant one more", %{
    project: project
  } do
    Fakes.Agent.script(:reviewer, [@changes])
    issue = project |> track() |> drive()

    assert issue.state == "needs_human"
    assert issue.hold_reason == "plan_rounds_exhausted"
    assert issue.plan_round == 3
    assert length(runs(issue, "planning")) == 3
    # Revisions are given the review they must resolve.
    assert Fakes.Agent.requests()
           |> Enum.filter(&(&1.role == :planner))
           |> List.last()
           |> Map.fetch!(:prompt) =~ "Fix X"

    Fakes.GitHub.add_comment(7, "maintainer", "ok\n/factory approve")
    issue = poll(issue)
    assert {issue.state, issue.plan_round_limit} == {"planning", 4}

    issue = drive(issue)
    assert {issue.state, issue.plan_round} == {"needs_human", 4}
  end

  test "time waiting for a person is counted apart from the factory's own time" do
    at = fn seconds -> DateTime.add(~U[2026-01-01 00:00:00Z], seconds) end

    step = fn state, from, to ->
      %{state: state, entered_at: at.(from), left_at: to && at.(to)}
    end

    transitions = [
      step.("queued", 0, 5),
      step.("planning", 5, 65),
      step.("awaiting_answers", 65, 3665),
      step.("planning", 3665, 3695),
      step.("needs_human", 3695, nil)
    ]

    now = at.(4695)
    assert Pipeline.time_in(transitions, Issue.factory_states(), now) == 95
    assert Pipeline.time_in(transitions, Issue.waiting_states(), now) == 4600
    assert Pipeline.time_in(transitions, ["pr_review"], now) == nil
  end

  describe "status on GitHub" do
    test "in progress from pickup, in review once the pull request is open, closed on merge", %{
      project: project
    } do
      Fakes.Agent.script(:planner, [
        planner(%{"status" => "questions", "questions" => ["Which?"]})
      ])

      issue = project |> track() |> drive()

      # Waiting for answers is still in progress.
      assert issue.state == "awaiting_answers"
      assert "factory:in-progress" in Fakes.GitHub.labels(7)

      Fakes.Agent.script(:planner, [planner(%{})])
      Fakes.GitHub.add_comment(7, "maintainer", "The first one")
      issue = issue |> poll() |> drive()

      assert issue.state == "ready_to_merge"
      assert "factory:in-review" in Fakes.GitHub.labels(7)
      refute "factory:in-progress" in Fakes.GitHub.labels(7)

      Fakes.GitHub.set_pr_state(100, "MERGED")
      assert poll(issue).state == "done"

      assert {:ok, %{state: "CLOSED"}} = Fakes.GitHub.get_issue("acme/app", 7)

      assert Enum.any?(
               Fakes.GitHub.posted(),
               &match?({7, "Pull request #100 was merged" <> _}, &1)
             )

      refute Enum.any?(Fakes.GitHub.labels(7), &String.starts_with?(&1, "factory:in-"))
    end

    test "a project can keep the issue open after the merge", %{project: project} do
      {:ok, project} = Projects.update_project(project, %{close_issue_on_merge: false})
      issue = project |> track() |> drive()

      Fakes.GitHub.set_pr_state(100, "MERGED")
      assert poll(issue).state == "done"

      assert {:ok, %{state: "OPEN"}} = Fakes.GitHub.get_issue("acme/app", 7)
      assert "factory:merged" in Fakes.GitHub.labels(7)
      refute "factory:in-review" in Fakes.GitHub.labels(7)
    end

    test "stopping removes the status and leaves the issue open", %{project: project} do
      issue = project |> track() |> drive()
      assert "factory:in-review" in Fakes.GitHub.labels(7)

      assert {:ok, %{state: "cancelled"}} = Poller.stop(issue)
      assert {:ok, %{state: "OPEN"}} = Fakes.GitHub.get_issue("acme/app", 7)
      refute Enum.any?(Fakes.GitHub.labels(7), &String.starts_with?(&1, "factory:in-"))
    end

    test "a pull request under revision stays in review" do
      alias Factory.Pipeline.GitHubStatus

      assert GitHubStatus.label(%Issue{state: "developing"}) == "factory:in-progress"
      assert GitHubStatus.label(%Issue{state: "developing", pr_number: 9}) == "factory:in-review"
      assert GitHubStatus.label(%Issue{state: "needs_human"}) == "factory:in-progress"
      assert GitHubStatus.label(%Issue{state: "done", pr_number: 9}) == nil
    end
  end

  test "the reviewer can run on Codex, the other roles only on Claude", %{project: project} do
    assert %{claude: _, codex: _} = Application.fetch_env!(:factory, :agent_runners)
    assert Factory.Agents.provider("gpt-6-astra") == :codex
    assert Factory.Agents.provider("claude-opus-5-5") == :claude

    {:ok, project} =
      Projects.update_project(project, %{reviewer_model: "gpt-6-astra", reviewer_effort: "high"})

    issue = project |> track() |> drive()

    assert issue.state == "ready_to_merge"
    assert [%{model: "gpt-6-astra", effort: "high", status: "ok"}] = runs(issue, "plan_review")
    assert [%{model: "gpt-6-astra"}] = runs(issue, "pr_review")

    assert {:error, changeset} = Projects.update_project(project, %{planner_model: "gpt-6-astra"})
    assert %{planner_model: ["is invalid"]} = errors_on(changeset)
  end

  test "an approval that still lists blocking problems counts as changes requested", %{
    project: project
  } do
    Fakes.Agent.script(:reviewer, [Map.put(@approve, "blocking", ["Could not read the diff"])])
    issue = project |> track() |> drive()

    assert {issue.state, issue.hold_reason} == {"needs_human", "plan_rounds_exhausted"}
  end

  test "stops for a person after three pull request review rounds", %{project: project} do
    Fakes.Agent.script(:reviewer, [@approve, @changes])
    issue = project |> track() |> drive()

    assert {issue.state, issue.hold_reason, issue.pr_round} ==
             {"needs_human", "pr_rounds_exhausted", 3}

    assert length(runs(issue, "developing")) == 3

    assert Fakes.Agent.requests()
           |> Enum.filter(&(&1.role == :developer))
           |> List.last()
           |> Map.fetch!(:prompt) =~ "Fix X"

    # The command also works when written on the pull request.
    Fakes.GitHub.add_comment(100, "maintainer", "/factory approve")
    Fakes.Agent.script(:reviewer, [@approve])
    issue = poll(issue)
    assert {issue.state, issue.pr_round_limit} == {"developing", 4}
    assert drive(issue).state == "ready_to_merge"
  end

  test "a hard issue waits for a person to approve the plan and uses the hard model", %{
    project: project
  } do
    Fakes.Agent.script(:planner, [planner(%{"difficulty" => "hard"})])
    issue = project |> track() |> drive()
    assert issue.state == "awaiting_plan_approval"

    Fakes.GitHub.add_comment(7, "maintainer", "/factory approve")
    issue = issue |> poll() |> drive()
    assert issue.state == "ready_to_merge"
    assert [%{model: "claude-opus-5-5", effort: "high"}] = runs(issue, "developing")
  end

  test "feedback on a plan awaiting approval sends it back to planning", %{project: project} do
    Fakes.Agent.script(:planner, [planner(%{"difficulty" => "hard"})])
    issue = project |> track() |> drive()
    Fakes.GitHub.add_comment(7, "maintainer", "Please keep the old endpoint too")
    assert poll(issue).state == "planning"
  end

  test "failing checks go back to the developer, the last attempt on a stronger model", %{
    project: project
  } do
    Fakes.Gates.script([{:error, "1 test failed"}, {:error, "1 test failed"}, :ok])
    issue = project |> track() |> drive()

    assert issue.state == "ready_to_merge"

    assert ["claude-sonnet-5-5", "claude-sonnet-5-5", "claude-opus-5-5"] ==
             Enum.map(runs(issue, "developing"), & &1.model)

    assert ["failed", "failed", "ok"] == Enum.map(runs(issue, "gates"), & &1.status)

    assert Fakes.Agent.requests()
           |> Enum.filter(&(&1.role == :developer))
           |> List.last()
           |> Map.fetch!(:prompt) =~ "1 test failed"
  end

  test "checks that keep failing stop for a person before any pull request", %{project: project} do
    Fakes.Gates.script([{:error, "boom"}])
    issue = project |> track() |> drive()

    assert {issue.state, issue.hold_reason, issue.pr_number} ==
             {"needs_human", "gates_failed", nil}
  end

  test "no pull request is opened when the developer changed no code", %{project: project} do
    Fakes.State.put(:code_changed?, false)
    issue = project |> track() |> drive()
    assert {issue.state, issue.hold_reason, issue.pr_number} == {"needs_human", "no_changes", nil}
  end

  test "an agent failure is surfaced and the stage can be retried", %{project: project} do
    Fakes.Agent.script(:developer, [
      {:error, "overloaded"},
      %{"status" => "done", "summary" => "ok"}
    ])

    issue = project |> track() |> drive()
    assert {issue.state, issue.resume_state} == {"failed", "developing"}
    assert issue.hold_detail =~ "overloaded"

    {:ok, issue} = Pipeline.approve(issue)
    assert drive(issue).state == "ready_to_merge"
  end

  test "closing the issue or /factory stop cancels the work", %{project: project} do
    Fakes.Agent.script(:planner, [planner(%{"status" => "questions", "questions" => ["Which?"]})])
    issue = project |> track() |> drive()
    Fakes.GitHub.add_comment(7, "maintainer", "/factory stop")
    assert poll(issue).state == "cancelled"
  end

  test "reads commands only at the start of a line" do
    assert Poller.commands(%{body: "fine\n  /factory Approve now"}) == ["approve"]
    assert Poller.commands(%{body: "do not run /factory stop please"}) == []
  end

  test "only an open pull request waiting for a person accepts changes" do
    accepts? = &Issue.accepts_pr_changes?(struct(Issue, &1))

    assert accepts?.(%{state: "ready_to_merge", pr_number: 9})
    assert accepts?.(%{state: "needs_human", hold_reason: "pr_rounds_exhausted", pr_number: 9})
    refute accepts?.(%{state: "ready_to_merge", pr_number: nil})
    refute accepts?.(%{state: "needs_human", hold_reason: "pr_rounds_exhausted", pr_number: nil})
    refute accepts?.(%{state: "needs_human", hold_reason: "gates_failed", pr_number: 9})
    refute accepts?.(%{state: "awaiting_plan_approval", pr_number: 9})
  end

  describe "requesting changes on the pull request" do
    test "from ready to merge it adds a round and enqueues the Developer", %{project: project} do
      issue = ready(project)
      assert {issue.pr_round, issue.pr_round_limit} == {1, 3}
      jobs = length(stage_jobs(issue, "developing"))

      assert {:ok, issue} = Pipeline.request_pr_changes(issue, "Rename the CSV", "note")

      assert {issue.state, issue.pr_round_limit, issue.pr_feedback} ==
               {"developing", 4, "Rename the CSV"}

      assert length(stage_jobs(issue, "developing")) == jobs + 1
      assert last_transition(issue).note == "note"
    end

    test "after the rounds ran out it grants one past the current round", %{project: project} do
      issue = exhausted(project)
      issue = Pipeline.update_issue(issue, %{pr_feedback: "Earlier"})

      assert {:ok, issue} = Pipeline.request_pr_changes(issue, "Ignore X, do Y", "note")
      assert issue.state == "developing"
      assert issue.pr_round_limit == issue.pr_round + 1
      assert {issue.hold_reason, issue.hold_detail, issue.resume_state} == {nil, nil, nil}
      assert issue.pr_feedback == "Earlier\n\n---\n\nIgnore X, do Y"
    end

    test "is refused while the issue is not waiting with its pull request", %{project: project} do
      issue = track(project)
      assert {:error, :not_accepting_pr_changes} = Pipeline.request_pr_changes(issue, "x", "n")
    end

    test "the same wait grants a single round, and never after a cancellation", %{
      project: project
    } do
      issue = ready(project)
      jobs = length(stage_jobs(issue, "developing"))

      assert {:ok, _} = Pipeline.request_pr_changes(issue, "A", "n")
      assert {:error, :not_accepting_pr_changes} = Pipeline.request_pr_changes(issue, "B", "n")
      assert Enum.count(Pipeline.list_transitions(issue), &(&1.note == "n")) == 1
      assert length(stage_jobs(issue, "developing")) == jobs + 1
      assert Pipeline.get_issue!(issue.id).pr_feedback == "A"
    end

    test "is refused after a cancellation", %{project: project} do
      issue = ready(project)
      {:ok, _} = Pipeline.cancel(issue)
      jobs = length(stage_jobs(issue, "developing"))

      assert {:error, :not_accepting_pr_changes} = Pipeline.request_pr_changes(issue, "C", "n")
      assert Pipeline.get_issue!(issue.id).state == "cancelled"
      assert length(stage_jobs(issue, "developing")) == jobs
    end

    test "before_commit can refuse it, and nothing is written", %{project: project} do
      issue = ready(project)
      transitions = Pipeline.list_transitions(issue)
      jobs = Repo.aggregate(Oban.Job, :count)
      job = CommentWorker.new_comment(issue, 100, "hello")

      assert {:error, :boom} =
               Pipeline.request_pr_changes(issue, "x", "n",
                 before_commit: fn _row -> {:error, :boom} end,
                 jobs: [job]
               )

      assert Pipeline.get_issue!(issue.id) == issue
      assert Pipeline.list_transitions(issue) == transitions
      assert Repo.aggregate(Oban.Job, :count) == jobs

      assert {:ok, _} =
               Pipeline.request_pr_changes(issue, "x", "n",
                 before_commit: fn row -> {:ok, row} end,
                 jobs: [job]
               )

      assert [%{args: %{"number" => 100}}] = comment_jobs()
    end

    test "a decision on an issue that moved on is stale and writes nothing", %{
      project: project
    } do
      issue = exhausted(project)
      {:ok, moved} = Pipeline.mark_pr_comments_seen(issue, DateTime.utc_now())
      guard = [unchanged_since: issue]

      assert {:error, :stale} = Pipeline.request_pr_changes(issue, "x", "n", guard)
      assert {:error, :stale} = Pipeline.approve(issue, "a person", guard)
      assert {:error, :stale} = Pipeline.cancel(issue, "n", guard)
      assert {:error, :stale} = Pipeline.mark_pr_comments_seen(issue, DateTime.utc_now())
      assert Pipeline.get_issue!(issue.id).state == "needs_human"
      assert Pipeline.get_issue!(issue.id).pr_comments_seen_at == moved.pr_comments_seen_at

      # The wait itself changing makes it stale too.
      Repo.update_all(from(i in Issue, where: i.id == ^issue.id),
        set: [state_entered_at: DateTime.utc_now()]
      )

      assert {:error, :stale} =
               Pipeline.request_pr_changes(moved, "x", "n", unchanged_since: moved)

      assert {:error, :stale} = Pipeline.cancel(moved, "n", unchanged_since: moved)
      assert Pipeline.get_issue!(issue.id).state == "needs_human"
    end

    test "the comments cursor never moves back", %{project: project} do
      issue = ready(project)
      later = DateTime.add(DateTime.utc_now(), 60)
      {:ok, issue} = Pipeline.mark_pr_comments_seen(issue, later)
      {:ok, issue} = Pipeline.mark_pr_comments_seen(issue, DateTime.utc_now())
      assert issue.pr_comments_seen_at == later

      {:ok, issue} =
        Pipeline.request_pr_changes(issue, "x", "n",
          unchanged_since: issue,
          seen_until: DateTime.utc_now()
        )

      assert issue.pr_comments_seen_at == later
    end

    test "a stopped issue stays stopped whatever a stage writes late", %{project: project} do
      issue = ready(project)
      {:ok, developing} = Pipeline.request_pr_changes(issue, "x", "n")
      {:ok, _} = Pipeline.cancel(developing)
      transitions = Pipeline.list_transitions(issue)
      jobs = Repo.aggregate(Oban.Job, :count)

      assert {:ok, %{state: "cancelled"}} = Pipeline.transition(developing, "pr_review")

      assert {:ok, %{state: "cancelled"}} =
               Pipeline.hold(developing, "gates_failed", "boom", "developing")

      assert {:ok, %{state: "cancelled"}} = Pipeline.fail(developing, "boom")

      assert Pipeline.get_issue!(issue.id).state == "cancelled"
      assert Pipeline.list_transitions(issue) == transitions
      assert Repo.aggregate(Oban.Job, :count) == jobs
    end

    test "runs start only while the issue is not stopped", %{project: project} do
      issue = ready(project)
      {:ok, developing} = Pipeline.request_pr_changes(issue, "x", "n")
      refute Pipeline.stopped?(developing)

      assert {:ok, %StageRun{status: "running"}} =
               Pipeline.authorize_run(developing, %{stage: "gates", role: "gates", round: 1})

      runs = length(Pipeline.list_runs(issue))
      {:ok, _} = Pipeline.cancel(developing)
      assert Pipeline.stopped?(developing)

      assert {:error, :stopped} =
               Pipeline.authorize_run(developing, %{stage: "gates", role: "gates", round: 2})

      assert length(Pipeline.list_runs(issue)) == runs
    end

    test "a merged issue is stopped too", %{project: project} do
      issue = ready(project)
      {:ok, done} = Pipeline.transition(issue, "done")
      assert Pipeline.stopped?(done)
    end

    test "a hold records its reason, and other holds are not pull request waits", %{
      project: project
    } do
      Fakes.Gates.script([{:error, "boom"}])
      issue = project |> track() |> drive()

      assert %Transition{state: "needs_human", hold_reason: "gates_failed"} =
               last_transition(issue)

      assert Pipeline.pr_waiting_periods(issue) == []
    end

    test "the pull request waits are listed, closed ones with their end", %{project: project} do
      issue = ready(project)
      {:ok, _} = Pipeline.request_pr_changes(issue, "x", "n")
      issue = drive(issue)
      assert issue.state == "ready_to_merge"

      assert [{_, %DateTime{}}, {entered_at, nil}] = Pipeline.pr_waiting_periods(issue)
      assert entered_at == issue.state_entered_at

      issue = exhausted_after(issue)
      assert %Transition{hold_reason: "pr_rounds_exhausted"} = last_transition(issue)
      assert length(Pipeline.pr_waiting_periods(issue)) == 3
    end

    test "a resumed stage runs even while its previous job is still executing", %{
      project: project
    } do
      Fakes.Gates.script([{:error, "boom"}])
      issue = project |> track() |> drive()
      assert issue.state == "needs_human"

      Repo.update_all(Oban.Job, set: [state: "completed"])

      job =
        Repo.one!(
          from j in Oban.Job,
            where: j.worker == "Factory.Workers.StageWorker",
            where: fragment("?->>'state' = 'developing'", j.args),
            order_by: [desc: j.id],
            limit: 1
        )

      Repo.update_all(from(j in Oban.Job, where: j.id == ^job.id), set: [state: "executing"])

      Fakes.Gates.script([:ok])
      developers = length(requests(:developer))
      {:ok, _} = Pipeline.approve(issue)

      assert %{success: 1} = Oban.drain_queue(queue: :agents)
      assert length(requests(:developer)) == developers + 1
    end
  end

  describe "cancelling while a stage runs" do
    # The issue in the state whose stage a test cancels, run up to it.
    defp reach(project, "planning"), do: track(project)

    defp reach(project, "plan_review") do
      {:ok, issue} = project |> track() |> Stages.run()
      assert issue.state == "plan_review"
      issue
    end

    defp reach(project, "developing") do
      {:ok, issue} = project |> ready() |> Pipeline.request_pr_changes("Rename the CSV", "n")
      issue
    end

    defp reach(project, "pr_review") do
      {:ok, issue} = project |> reach("developing") |> Stages.run()
      assert issue.state == "pr_review"
      issue
    end

    defp assert_stays_cancelled(issue) do
      assert Pipeline.get_issue!(issue.id).state == "cancelled"
      assert last_transition(issue).state == "cancelled"
      refute Stages.needs_human_label() in Fakes.GitHub.labels(7)
    end

    test "a stage whose job starts after the cancellation runs nothing", %{project: project} do
      snapshot = reach(project, "developing") |> then(&Pipeline.get_issue!(&1.id))
      {:ok, _} = Pipeline.cancel(snapshot)
      before = effects(snapshot)

      assert {:ok, _} = Stages.run(snapshot)
      assert effects(snapshot) == before
      assert_stays_cancelled(snapshot)
    end

    for {state, role, absent} <- [
          {"planning", :planner, []},
          {"plan_review", :reviewer, ["Plan ready"]},
          {"developing", :developer, ["Changes pushed"]},
          {"pr_review", :reviewer, ["Review round", "passed review"]}
        ] do
      test "cancelling while the #{role} works in #{state} stops everything after it", %{
        project: project
      } do
        issue = reach(project, unquote(state))
        Fakes.Agent.script(:reviewer, [@approve])
        before = effects(issue)
        Fakes.Agent.during(unquote(role), cancel_now(issue))

        assert {:ok, _} = Stages.run(Pipeline.get_issue!(issue.id))
        after_ = effects(issue)

        assert length(after_.requests) == length(before.requests) + 1
        assert List.last(after_.requests).role == unquote(role)
        assert after_.posted == before.posted
        assert after_.commits == before.commits
        assert after_.pushes == before.pushes

        for {_, body} <- after_.posted -- before.posted,
            text <- unquote(absent),
            do: refute(body =~ text)

        refute Enum.any?(
                 Pipeline.list_transitions(issue),
                 &(&1.state == "ready_to_merge" and is_nil(&1.left_at))
               )

        assert_stays_cancelled(issue)
      end
    end

    for {name, answer} <- [
          {"blocked", %{"status" => "blocked", "summary" => "No", "blocked_reason" => "Keys"}},
          {"failing", {:error, "boom"}}
        ] do
      test "a #{name} Developer after the cancellation is neither reported nor failed", %{
        project: project
      } do
        issue = reach(project, "developing")
        Fakes.Agent.script(:developer, [unquote(Macro.escape(answer))])
        before = effects(issue)
        Fakes.Agent.during(:developer, cancel_now(issue))

        assert {:ok, _} = Stages.run(Pipeline.get_issue!(issue.id))
        assert effects(issue).posted == before.posted

        refute Enum.any?(
                 Pipeline.list_transitions(issue),
                 &(&1.state in ~w(failed needs_human) and &1.entered_at > issue.state_entered_at)
               )

        assert_stays_cancelled(issue)
      end
    end

    test "cancelling during the last failing check stops for no one", %{project: project} do
      issue = reach(project, "developing")
      Fakes.Gates.script([{:error, "x"}, {:error, "x"}, {:error, "x"}])
      before = effects(issue)
      Fakes.Gates.during(3, cancel_now(issue))

      assert {:ok, _} = Stages.run(Pipeline.get_issue!(issue.id))
      refute Enum.any?(Fakes.GitHub.posted(), fn {_, body} -> body =~ "checks still fail" end)
      assert effects(issue).posted == before.posted

      assert length(requests(:developer)) ==
               length(Enum.filter(before.requests, &(&1.role == :developer))) + 3

      assert_stays_cancelled(issue)
    end

    test "cancelling during the first check starts no other attempt", %{project: project} do
      issue = reach(project, "developing")
      Fakes.Gates.script([{:error, "x"}])
      developers = length(requests(:developer))
      Fakes.Gates.during(1, cancel_now(issue))

      assert {:ok, _} = Stages.run(Pipeline.get_issue!(issue.id))
      assert length(requests(:developer)) == developers + 1
      assert length(runs(issue, "gates")) == 2

      assert [%{round: 1}] =
               issue |> runs("gates") |> Enum.filter(&(&1.started_at > issue.state_entered_at))

      assert_stays_cancelled(issue)
    end

    test "the status label is not put back on an issue cancelled meanwhile", %{project: project} do
      {:ok, issue} = project |> track() |> Stages.run()
      {:ok, issue} = Stages.run(issue)
      assert issue.state == "developing"

      Fakes.GitHub.during({:set_label, "factory:in-progress", false}, 7, cancel_now(issue))
      assert {:ok, _} = Stages.run(issue)

      refute "factory:in-review" in Fakes.GitHub.labels(7)
      assert_stays_cancelled(issue)
    end
  end
end
