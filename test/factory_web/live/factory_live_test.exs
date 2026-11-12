defmodule FactoryWeb.FactoryLiveTest do
  use FactoryWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias Factory.Fakes
  alias Factory.{Pipeline, Projects}
  alias Factory.Pipeline.Stages

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

    # Posted as the person's own comment, without the factory's marker.
    assert {7, "Use JSON, not CSV"} in Fakes.GitHub.posted()
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
end
