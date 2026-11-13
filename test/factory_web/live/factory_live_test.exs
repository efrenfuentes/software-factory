defmodule FactoryWeb.FactoryLiveTest do
  use FactoryWeb.ConnCase, async: false
  use Oban.Testing, repo: Factory.Repo
  import Phoenix.LiveViewTest

  alias Factory.Fakes
  alias Factory.{Pipeline, Projects}
  alias Factory.Pipeline.Stages

  setup :sign_in

  setup do
    Fakes.State.reset()
    :ok
  end

  defp project do
    {:ok, project} =
      Projects.create_project(%{
        repo: "acme/app",
        app_type: "elixir",
        allowed_users: "maintainer"
      })

    project
  end

  defp run_to_rest(issue) do
    issue = Pipeline.get_issue!(issue.id)

    if Pipeline.Issue.active?(issue),
      do: issue |> Stages.run() |> elem(1) |> run_to_rest(),
      else: issue
  end

  test "the dashboard points to project setup when there is nothing yet", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    assert has_element?(view, "#empty-state a[href='/projects/new']")
  end

  test "a project is created with the logged-in GitHub user allowed and the default models", %{
    conn: conn
  } do
    {:ok, view, _html} = live(conn, ~p"/projects/new")

    assert has_element?(
             view,
             "#project-form input[name='project[allowed_users]'][value='maintainer']"
           )

    assert view |> form("#project-form", project: %{repo: "not a repo"}) |> render_change() =~
             "must look like owner/name"

    # Codex models are offered for the Reviewer only.
    assert has_element?(
             view,
             "select[name='project[reviewer_model]'] option[value='gpt-6-astra']"
           )

    refute has_element?(view, "select[name='project[planner_model]'] option[value='gpt-6-astra']")

    view
    |> form("#project-form",
      project: %{repo: "acme/api", app_type: "rails", reviewer_model: "gpt-6.1-sol"}
    )
    |> render_submit()

    assert_redirect(view, ~p"/projects")

    assert [
             %{
               repo: "acme/api",
               app_type: "rails",
               dev_easy_model: "claude-sonnet-5-5",
               reviewer_model: "gpt-6.1-sol"
             }
           ] = Projects.list_projects()
  end

  test "the dashboard lists an issue with its stage and the model of each stage", %{conn: conn} do
    Fakes.GitHub.put_issue(7, title: "Add export")

    {:ok, issue} =
      Pipeline.track_issue(project(), %{number: 7, title: "Add export", body: "", url: "u"})

    {:ok, view, _html} = live(conn, ~p"/")
    assert has_element?(view, "#issue-#{issue.id}", "Planning")

    run_to_rest(issue)
    assert has_element?(view, "#issue-#{issue.id}", "Ready to merge")
    assert has_element?(view, "#issue-#{issue.id}", "Sonnet 5.5")
    assert has_element?(view, "#stat-waiting", "1")
    assert has_element?(view, "#issue-#{issue.id}-factory-time")
    assert has_element?(view, "#issue-#{issue.id}-waiting-time")

    {:ok, view, _html} = live(conn, ~p"/issues/#{issue.id}")
    assert has_element?(view, "#factory-time")
    assert has_element?(view, "#waiting-time")
  end

  test "a person can allow one more round from the issue page", %{conn: conn} do
    Fakes.GitHub.put_issue(7, title: "Add export")

    Fakes.Agent.script(:reviewer, [
      %{
        "verdict" => "changes_requested",
        "summary" => "No",
        "blocking" => ["Fix X"],
        "minor" => []
      }
    ])

    {:ok, issue} =
      Pipeline.track_issue(project(), %{number: 7, title: "Add export", body: "", url: "u"})

    issue = run_to_rest(issue)

    {:ok, view, _html} = live(conn, ~p"/issues/#{issue.id}")
    assert has_element?(view, "#hold-notice")
    assert has_element?(view, "#runs", "Fix X")

    view |> element("#approve-button", "Allow one more round") |> render_click()
    assert %{state: "planning", plan_round_limit: 4} = Pipeline.get_issue!(issue.id)

    view |> element("#stop-button") |> render_click()
    assert Pipeline.get_issue!(issue.id).state == "cancelled"
    refute has_element?(view, "#stop-button")
  end

  test "a person reads the plan on the issue page and asks for changes or approves it", %{
    conn: conn
  } do
    Fakes.GitHub.put_issue(7, title: "Add export")

    Fakes.Agent.script(:planner, [
      %{
        "status" => "ready",
        "summary" => "Plan",
        "questions" => [],
        "difficulty" => "hard",
        "difficulty_reason" => "migration"
      }
    ])

    {:ok, issue} =
      Pipeline.track_issue(project(), %{number: 7, title: "Add export", body: "", url: "u"})

    {:ok, view, _html} = live(conn, ~p"/issues/#{issue.id}")
    refute has_element?(view, "#plan")

    Fakes.State.put(:plan, [
      %{name: "spec.md", content: "# Spec\n\nExport as **CSV** <script>alert(1)</script>"},
      %{name: "plan.md", content: "Add `Exporter`"},
      %{name: "tasks.md", content: "- [ ] T1 Write the exporter"}
    ])

    issue = run_to_rest(issue)
    assert issue.state == "awaiting_plan_approval"

    refute has_element?(view, "#pr-feedback-form")

    # Open on the spec while it waits for a decision, rendered and sanitized.
    assert has_element?(view, "#plan-content strong", "CSV")
    refute has_element?(view, "#plan-content script")

    view |> element("#plan-tab-tasks") |> render_click()
    assert has_element?(view, "#plan-content li", "T1 Write the exporter")

    assert view |> form("#plan-feedback-form", review: %{feedback: "  "}) |> render_submit() =~
             "Write what should change"

    view
    |> form("#plan-feedback-form", review: %{feedback: "Use JSON, not CSV"})
    |> render_submit()

    # Posted as a person's comment, without the factory's marker, saying who wrote it.
    assert {7, "Use JSON, not CSV\n\n_Sent from Software Factory by Ana Pérez._"} in Fakes.GitHub.posted()
    assert Pipeline.get_issue!(issue.id).state == "planning"
    refute has_element?(view, "#plan-feedback-form")

    issue = run_to_rest(issue)
    assert issue.state == "awaiting_plan_approval"
    view |> element("#approve-plan-button") |> render_click()
    assert Pipeline.get_issue!(issue.id).state == "developing"

    # Still readable afterwards, folded away.
    assert has_element?(view, "#plan-toggle")
    refute has_element?(view, "#plan-content")
    view |> element("#plan-toggle") |> render_click()
    assert has_element?(view, "#plan-content")
  end

  describe "changes to the pull request" do
    defp ready_issue do
      Fakes.GitHub.put_issue(7, title: "Add export")

      {:ok, issue} =
        Pipeline.track_issue(project(), %{number: 7, title: "Add export", body: "", url: "u"})

      issue = run_to_rest(issue)
      assert issue.state == "ready_to_merge"
      issue
    end

    defp panel_posts, do: Enum.filter(Fakes.GitHub.posted(), &match?({100, "Rename" <> _}, &1))

    defp submit(view, text),
      do: view |> form("#pr-feedback-form", pr_changes: %{feedback: text}) |> render_submit()

    test "a person asks for changes and their comment is posted on the pull request", %{
      conn: conn
    } do
      issue = ready_issue()
      {:ok, view, _html} = live(conn, ~p"/issues/#{issue.id}")
      assert has_element?(view, "#pr-feedback-form")

      assert submit(view, "  ") =~ "Write what should change"
      assert Pipeline.get_issue!(issue.id).state == "ready_to_merge"

      submit(view, "Rename the CSV")
      assert Pipeline.get_issue!(issue.id).state == "developing"

      assert has_element?(
               view,
               "#transitions",
               "Changes to the pull request requested by Ana Pérez"
             )

      refute has_element?(view, "#pr-feedback-form")
      assert panel_posts() == []

      assert %{success: 1} = Oban.drain_queue(queue: :github)
      assert [{100, body}] = panel_posts()

      assert String.starts_with?(
               body,
               "Rename the CSV\n\n_Sent from Software Factory by Ana Pérez._"
             )

      assert Factory.Pipeline.Poller.panel_comment?(%{body: body})
    end

    test "the comment is posted once GitHub answers again", %{conn: conn} do
      issue = ready_issue()
      Fakes.GitHub.fail(:comment, 100)
      {:ok, view, _html} = live(conn, ~p"/issues/#{issue.id}")
      submit(view, "Rename the CSV")

      assert Pipeline.get_issue!(issue.id).state == "developing"
      Oban.drain_queue(queue: :github)
      assert panel_posts() == []

      Fakes.GitHub.recover(:comment, 100)
      assert %{success: 1} = Oban.drain_queue(queue: :github, with_scheduled: true)
      assert [_] = panel_posts()
    end

    test "nothing is sent when the pull request cannot be read or is not open", %{conn: conn} do
      issue = ready_issue()
      {:ok, view, _html} = live(conn, ~p"/issues/#{issue.id}")

      Fakes.GitHub.fail(:get_pr, 100)
      assert submit(view, "Rename the CSV") =~ "Could not read the pull request"
      Fakes.GitHub.recover(:get_pr, 100)

      Fakes.GitHub.set_pr_state(100, "MERGED")
      assert submit(view, "Rename the CSV") =~ "no longer open"

      assert Pipeline.get_issue!(issue.id).state == "ready_to_merge"
      assert all_enqueued(worker: Factory.Workers.CommentWorker) == []
      Oban.drain_queue(queue: :github)
      assert panel_posts() == []
    end

    test "a round opened meanwhile refuses the request", %{conn: conn} do
      issue = ready_issue()
      {:ok, view, _html} = live(conn, ~p"/issues/#{issue.id}")
      assert has_element?(view, "#pr-feedback-form")
      {:ok, _} = Pipeline.request_pr_changes(issue, "Other", "Other round")

      assert render_hook(view, "request_pr_changes", %{"pr_changes" => %{"feedback" => "x"}}) =~
               "not waiting for changes"

      assert all_enqueued(worker: Factory.Workers.CommentWorker) == []
    end

    test "is not offered while held for another reason", %{conn: conn} do
      issue = ready_issue()
      {:ok, held} = Pipeline.hold(issue, "gates_failed", "boom", "developing")
      {:ok, view, _html} = live(conn, ~p"/issues/#{held.id}")
      assert has_element?(view, "#hold-notice")
      refute has_element?(view, "#pr-feedback-form")
    end
  end
end
