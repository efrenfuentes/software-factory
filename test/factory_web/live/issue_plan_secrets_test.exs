defmodule FactoryWeb.IssuePlanSecretsTest do
  # Changes the application's configuration (the secrets key).
  use FactoryWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias Factory.{Fakes, Pipeline, Projects, Secrets}

  @value "plan-secret-value-7"

  @moduletag role: "viewer"
  setup :sign_in

  setup do
    Fakes.State.reset()
    key = Application.get_env(:factory, :secrets_key)
    on_exit(fn -> Application.put_env(:factory, :secrets_key, key) end)

    {:ok, project} =
      Projects.create_project(%{repo: "acme/app", app_type: "elixir", allowed_users: "m"})

    admin = Factory.AccountsFixtures.user_fixture(role: "admin")

    {:ok, _} =
      Secrets.create_secret(project, %{"name" => "API_KEY", "value" => @value}, admin)

    Fakes.GitHub.put_issue(7, title: "Add export")

    {:ok, issue} =
      Pipeline.track_issue(project, %{number: 7, title: "Add export", body: "", url: "u"})

    # What the Planner committed, before the push was checked.
    Fakes.State.put(:plan, [
      %{name: "spec.md", content: "Call the API with `#{@value}`."},
      %{name: "plan.md", content: "Use #{@value} again"},
      %{name: "tasks.md", content: "- [ ] T1 #{@value}"}
    ])

    issue = Pipeline.update_issue(issue, %{state: "awaiting_plan_approval"})
    %{issue: issue}
  end

  defp leaked?(view) do
    render(view) =~ @value or inspect(:sys.get_state(view.pid), limit: :infinity) =~ @value
  end

  test "a viewer reads the plan with the secret values replaced, before and after the push is refused",
       %{conn: conn, issue: issue} do
    {:ok, view, _html} = live(conn, ~p"/issues/#{issue.id}")

    assert has_element?(view, "#plan-content", "[SECRET:API_KEY]")
    refute leaked?(view)

    for tab <- ~w(plan tasks) do
      view |> element("#plan-tab-#{tab}") |> render_click()
      assert has_element?(view, "#plan-content", "[SECRET:API_KEY]")
      refute leaked?(view)
    end

    {:ok, issue} =
      Pipeline.hold(issue, "secret_in_diff", "The commits contain API_KEY", "planning")

    send(view.pid, {:issue_updated, issue.id})
    view |> element("#plan-toggle") |> render_click()
    assert has_element?(view, "#plan-content", "[SECRET:API_KEY]")
    refute leaked?(view)
  end

  test "without the key to decrypt the secrets, the plan's content is hidden", %{
    conn: conn,
    issue: issue
  } do
    Application.put_env(:factory, :secrets_key, nil)
    {:ok, view, _html} = live(conn, ~p"/issues/#{issue.id}")

    assert has_element?(view, "#plan-content", "Hidden")
    refute leaked?(view)
  end
end
