defmodule Factory.Workers.CommentWorkerTest do
  use Factory.DataCase, async: false
  use Oban.Testing, repo: Factory.Repo

  alias Factory.Fakes
  alias Factory.Fakes.GitHub
  alias Factory.{Pipeline, Projects}
  alias Factory.Pipeline.Poller
  alias Factory.Workers.CommentWorker

  setup do
    Fakes.State.reset()
    GitHub.put_issue(7, title: "Add export")
    GitHub.put_issue(100, title: "Add export")

    {:ok, project} =
      Projects.create_project(%{
        repo: "acme/app",
        app_type: "elixir",
        allowed_users: "maintainer"
      })

    {:ok, issue} =
      Pipeline.track_issue(project, %{number: 7, title: "Add export", body: "Body", url: "u"})

    job = CommentWorker.new_comment(issue, 100, "Rename the CSV")
    %{args: Map.new(job.changes.args, fn {k, v} -> {to_string(k), v} end)}
  end

  defp perform(args), do: perform_job(CommentWorker, args)

  test "posts the comment once, with its hidden mark", %{args: args} do
    assert :ok = perform(args)
    assert [{100, body}] = GitHub.posted()
    assert body == "Rename the CSV\n\n" <> Poller.panel_mark(args["token"])
    assert Poller.panel_comment?(%{body: body})
  end

  test "a failure to post is retried until it goes through", %{args: args} do
    GitHub.fail(:comment, 100)
    assert {:error, _} = perform(args)
    assert GitHub.posted() == []

    GitHub.recover(:comment, 100)
    assert :ok = perform(args)
    assert [{100, _}] = GitHub.posted()
  end

  test "a retry after a lost answer does not post twice", %{args: args} do
    GitHub.fail(:comment, 100, :after)
    assert {:error, _} = perform(args)
    assert [{100, _}] = GitHub.posted()

    GitHub.recover(:comment, 100)
    assert :ok = perform(args)
    assert [{100, _}] = GitHub.posted()
  end

  test "nothing is posted when the pull request cannot be read", %{args: args} do
    GitHub.fail(:get_issue, 100)
    assert {:error, _} = perform(args)
    assert GitHub.posted() == []
  end

  test "backs off longer on each attempt, up to ten minutes" do
    assert CommentWorker.backoff(%Oban.Job{attempt: 1}) == 30
    assert CommentWorker.backoff(%Oban.Job{attempt: 30}) == 600
  end
end
