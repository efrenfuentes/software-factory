defmodule Factory.PipelineConcurrencyTest do
  @moduledoc """
  Real row locks between connections: these tests run outside the SQL sandbox,
  commit their rows and delete them afterwards.
  """
  use ExUnit.Case, async: false
  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Factory.{Fakes, Pipeline, Projects, Repo}
  alias Factory.Pipeline.{Issue, StageRun, Transition}
  alias Factory.Workers.StageWorker

  @repo "acme/concurrency"

  setup do
    Fakes.State.reset()

    issue =
      unboxed(fn ->
        {:ok, project} =
          Projects.create_project(%{repo: @repo, app_type: "elixir", allowed_users: "maintainer"})

        {:ok, issue} =
          Pipeline.track_issue(project, %{number: 7, title: "Add export", body: "", url: "u"})

        {:ok, issue} =
          Pipeline.transition(
            issue,
            "ready_to_merge",
            %{pr_number: 100, pr_url: "https://github.com/#{@repo}/pull/100", pr_round: 1},
            "Approved in review round 1"
          )

        issue
      end)

    on_exit(fn ->
      unboxed(fn ->
        Repo.delete_all(
          from j in Oban.Job, where: fragment("(?->>'issue_id')::bigint = ?", j.args, ^issue.id)
        )

        Repo.delete_all(from p in Factory.Projects.Project, where: p.repo == @repo)
      end)
    end)

    %{issue: issue}
  end

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)

  defp async(fun), do: Task.async(fn -> unboxed(fun) end)

  defp lock_row!(issue),
    do: Repo.one!(from i in Issue, where: i.id == ^issue.id, lock: "FOR UPDATE")

  # Waits until `n` other connections are blocked on a lock.
  defp await_waiting(n, tries \\ 250) do
    Repo.query!("SELECT pg_stat_clear_snapshot()")

    %{rows: [[waiting]]} =
      Repo.query!(
        "SELECT count(*) FROM pg_stat_activity WHERE wait_event_type = 'Lock' AND datname = current_database()"
      )

    cond do
      waiting >= n ->
        :ok

      tries == 0 ->
        flunk("expected #{n} connection(s) waiting on a lock, saw #{waiting}")

      true ->
        Process.sleep(20)
        await_waiting(n, tries - 1)
    end
  end

  defp request(issue, test) do
    async(fn ->
      Pipeline.request_pr_changes(issue, "Rename the CSV", "Changes requested",
        before_commit: fn row ->
          send(test, {:before_commit, self()})
          {:ok, row}
        end
      )
    end)
  end

  defp developing_jobs(issue) do
    Repo.all(
      from j in Oban.Job,
        where: j.worker == "Factory.Workers.StageWorker",
        where: fragment("(?->>'issue_id')::bigint = ?", j.args, ^issue.id),
        where: fragment("?->>'state' = 'developing'", j.args)
    )
  end

  test "of two requests at once only the first grants a round", %{issue: issue} do
    test = self()

    tasks =
      unboxed(fn ->
        {:ok, tasks} =
          Repo.transaction(fn ->
            lock_row!(issue)
            tasks = [request(issue, test), request(issue, test)]
            await_waiting(2)
            tasks
          end)

        tasks
      end)

    results = Enum.map(tasks, &Task.await(&1, 5000))
    assert Enum.count(results, &match?({:ok, %Issue{state: "developing"}}, &1)) == 1
    assert {:error, :not_accepting_pr_changes} in results

    assert_received {:before_commit, _}
    refute_received {:before_commit, _}

    unboxed(fn ->
      assert Pipeline.get_issue!(issue.id).pr_round_limit == issue.pr_round_limit + 1
      assert Enum.count(Pipeline.list_transitions(issue), &(&1.state == "developing")) == 1
      assert length(developing_jobs(issue)) == 1
    end)
  end

  test "a request and a cancellation at once both finish, and the issue stays cancelled", %{
    issue: issue
  } do
    test = self()

    tasks =
      unboxed(fn ->
        {:ok, tasks} =
          Repo.transaction(fn ->
            lock_row!(issue)
            tasks = [request(issue, test), async(fn -> Pipeline.cancel(issue) end)]
            await_waiting(2)
            tasks
          end)

        tasks
      end)

    Enum.each(tasks, &Task.await(&1, 5000))

    unboxed(fn ->
      assert Pipeline.get_issue!(issue.id).state == "cancelled"

      assert [%Transition{state: "cancelled"}] =
               Enum.filter(Pipeline.list_transitions(issue), &is_nil(&1.left_at))

      Oban.drain_queue(queue: :agents)
    end)

    assert Fakes.Agent.requests() == []
  end

  test "a round's job that starts while a cancellation is being written runs no agent", %{
    issue: issue
  } do
    unboxed(fn ->
      {:ok, _} = Pipeline.request_pr_changes(issue, "Rename the CSV", "Changes requested")
    end)

    [job] = unboxed(fn -> developing_jobs(issue) end)

    task =
      unboxed(fn ->
        {:ok, task} =
          Repo.transaction(fn ->
            {:ok, _} = Pipeline.cancel(issue)
            task = async(fn -> StageWorker.perform(job) end)
            await_waiting(1)
            task
          end)

        task
      end)

    assert :ok = Task.await(task, 5000)
    assert Fakes.Agent.requests() == []

    unboxed(fn ->
      assert Pipeline.get_issue!(issue.id).state == "cancelled"
      assert Repo.all(from r in StageRun, where: r.issue_id == ^issue.id) == []
    end)
  end

  test "a cancellation waits for a run being authorized, which counts as started", %{
    issue: issue
  } do
    {run, task} =
      unboxed(fn ->
        {:ok, result} =
          Repo.transaction(fn ->
            {:ok, run} =
              Pipeline.authorize_run(issue, %{stage: "gates", role: "gates", round: 1})

            task = async(fn -> Pipeline.cancel(issue) end)
            await_waiting(1)
            {run, task}
          end)

        result
      end)

    assert {:ok, _} = Task.await(task, 5000)

    unboxed(fn ->
      assert Repo.get(StageRun, run.id)
      assert %Transition{state: "cancelled"} = issue |> Pipeline.list_transitions() |> List.last()
    end)
  end
end
