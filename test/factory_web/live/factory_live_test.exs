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

    view
    |> form("#project-form", project: %{repo: "acme/api", app_type: "rails"})
    |> render_submit()

    assert_redirect(view, ~p"/projects")

    assert [%{repo: "acme/api", app_type: "rails", dev_easy_model: "claude-sonnet-5-5"}] =
             Projects.list_projects()
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
end
