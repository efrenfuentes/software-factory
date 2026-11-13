defmodule FactoryWeb.UsersTest do
  use FactoryWeb.ConnCase, async: false
  use Oban.Testing, repo: Factory.Repo
  import Phoenix.LiveViewTest
  import Factory.AccountsFixtures

  alias Factory.{Accounts, Fakes, Pipeline, Projects}

  setup do
    Fakes.State.reset()
    :ok
  end

  defp run_to_rest(issue) do
    issue = Pipeline.get_issue!(issue.id)

    if Pipeline.Issue.active?(issue),
      do: issue |> Factory.Pipeline.Stages.run() |> elem(1) |> run_to_rest(),
      else: issue
  end

  describe "signing in" do
    test "a new factory asks for its first administrator, once", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/setup"}}} = live(conn, ~p"/")
      assert {:error, {:redirect, %{to: "/setup"}}} = live(conn, ~p"/users/log-in")

      {:ok, view, _html} = live(conn, ~p"/setup")

      view
      |> form("#setup-form",
        user: %{
          first_name: "Ana",
          last_name: "Pérez",
          email: "ana@example.com",
          password: valid_password()
        }
      )
      |> render_submit()

      assert_redirect(view, ~p"/users/log-in")
      assert [%{role: "admin", first_name: "Ana"}] = Accounts.list_users()
      assert {:error, {:redirect, %{to: "/users/log-in"}}} = live(conn, ~p"/setup")
    end

    test "with email and password; pages need it and signing out ends it", %{conn: conn} do
      user = user_fixture(email: "ana@example.com")

      assert {:error, {:redirect, %{to: "/users/log-in"}}} = live(conn, ~p"/")
      assert redirected_to(get(conn, ~p"/projects")) == ~p"/users/log-in"

      {:ok, view, _html} = live(conn, ~p"/users/log-in")
      assert has_element?(view, "#login-form")

      wrong = post(conn, ~p"/users/log-in", user: %{email: user.email, password: "nope"})
      assert redirected_to(wrong) == ~p"/users/log-in"
      assert Phoenix.Flash.get(wrong.assigns.flash, :error) =~ "not correct"

      conn = post(conn, ~p"/users/log-in", user: %{email: user.email, password: valid_password()})
      assert redirected_to(conn) == ~p"/"

      {:ok, view, _html} = live(conn, ~p"/account")
      assert has_element?(view, "#account-name", "Ana Pérez")

      conn = delete(conn, ~p"/users/log-out")
      assert redirected_to(conn) == ~p"/users/log-in"
      assert {:error, {:redirect, %{to: "/users/log-in"}}} = live(conn, ~p"/")
    end

    test "a person changes their own password and is signed out", %{conn: conn} do
      user = user_fixture()
      {:ok, view, _html} = conn |> log_in_user(user) |> live(~p"/account")

      view
      |> form("#password-form",
        user: %{
          current_password: valid_password(),
          password: "a brand new password",
          password_confirmation: "a brand new password"
        }
      )
      |> render_submit()

      assert_redirect(view, ~p"/users/log-in")
      assert Accounts.authenticate(user.email, "a brand new password")
    end
  end

  describe "administrators" do
    setup :sign_in

    test "add people and change their access", %{conn: conn, user: admin} do
      {:ok, view, _html} = live(conn, ~p"/users")
      assert has_element?(view, "#user-#{admin.id}", "(you)")

      {:ok, view, _html} = live(conn, ~p"/users/new")

      assert view |> form("#user-form", user: %{first_name: "", email: "x"}) |> render_change() =~
               "must be an email address"

      view
      |> form("#user-form",
        user: %{
          first_name: "Luis",
          last_name: "Gómez Ruiz",
          email: "luis@example.com",
          role: "operator",
          password: valid_password()
        }
      )
      |> render_submit()

      assert_redirect(view, ~p"/users")
      luis = Enum.find(Accounts.list_users(), &(&1.email == "luis@example.com"))
      assert %{first_name: "Luis", last_name: "Gómez Ruiz", role: "operator"} = luis

      # Changing the access ends that person's sessions.
      token = Accounts.create_session(luis)
      {:ok, view, _html} = live(conn, ~p"/users/#{luis.id}/edit")
      view |> form("#user-form", user: %{role: "viewer", active: false}) |> render_submit()

      assert %{role: "viewer", active: false} = Accounts.get_user!(luis.id)
      refute Accounts.get_user_by_session(token)
    end

    test "cannot remove the only administrator", %{conn: conn, user: admin} do
      {:ok, view, _html} = live(conn, ~p"/users/#{admin.id}/edit")

      # The form does not offer it...
      assert has_element?(view, "#last-admin-note")
      assert has_element?(view, "select[name='user[role]'][disabled]")
      assert has_element?(view, "input[type=checkbox][name='user[active]'][disabled]")

      # ...and the server refuses it when sent anyway.
      for change <- [%{"role" => "viewer"}, %{"role" => "operator"}, %{"active" => "false"}] do
        assert render_hook(view, "save", %{"user" => change}) =~ "only active administrator"
      end

      assert %{role: "admin", active: true} = Accounts.get_user!(admin.id)

      # A deactivated administrator does not count as another one.
      other = user_fixture()
      {:ok, _} = Accounts.update_user(other, %{active: false})
      assert Accounts.last_admin?(Accounts.get_user!(admin.id))

      # With a second active administrator the access can change.
      user_fixture()
      {:ok, view, _html} = live(conn, ~p"/users/#{admin.id}/edit")
      refute has_element?(view, "#last-admin-note")
      refute has_element?(view, "select[name='user[role]'][disabled]")
    end
  end

  describe "operators" do
    @describetag role: "operator"
    setup :sign_in

    test "act on issues but cannot reach projects or users", %{conn: conn} do
      {:ok, project} =
        Projects.create_project(%{repo: "acme/app", app_type: "elixir", allowed_users: "m"})

      for path <- [
            ~p"/users",
            ~p"/users/new",
            ~p"/projects/new",
            ~p"/projects/#{project.id}/edit"
          ] do
        assert {:error, {:redirect, %{to: "/", flash: %{"error" => "Only administrators" <> _}}}} =
                 live(conn, path)
      end

      {:ok, view, _html} = live(conn, ~p"/projects")
      refute has_element?(view, "#new-project")
      refute has_element?(view, "#project-#{project.id} a")
      # The form's events are refused even when sent by hand.
      assert render_hook(view, "save", %{"project" => %{"repo" => "acme/other"}}) =~
               "Only administrators"

      assert [_only_one] = Projects.list_projects()
      refute has_element?(view, "a[href='/users']")

      Fakes.GitHub.put_issue(7, title: "Add export")

      {:ok, issue} =
        Pipeline.track_issue(project, %{number: 7, title: "Add export", body: "", url: "u"})

      {:ok, view, _html} = live(conn, ~p"/issues/#{issue.id}")
      view |> element("#stop-button") |> render_click()
      assert Pipeline.get_issue!(issue.id).state == "cancelled"
      # Who did it is recorded.
      assert has_element?(view, "#transitions", "Stopped by Ana Pérez")
    end

    test "ask for changes to a pull request", %{conn: conn} do
      {:ok, project} =
        Projects.create_project(%{repo: "acme/app", app_type: "elixir", allowed_users: "m"})

      Fakes.GitHub.put_issue(7, title: "Add export")

      {:ok, issue} =
        Pipeline.track_issue(project, %{number: 7, title: "Add export", body: "", url: "u"})

      issue = run_to_rest(issue)
      assert issue.state == "ready_to_merge"

      {:ok, view, _html} = live(conn, ~p"/issues/#{issue.id}")

      view
      |> form("#pr-feedback-form", pr_changes: %{feedback: "Rename the CSV"})
      |> render_submit()

      assert Pipeline.get_issue!(issue.id).state == "developing"
    end
  end

  describe "read-only users" do
    @describetag role: "viewer"
    setup :sign_in

    test "see everything and can change nothing", %{conn: conn} do
      {:ok, project} =
        Projects.create_project(%{repo: "acme/app", app_type: "elixir", allowed_users: "m"})

      Fakes.GitHub.put_issue(7, title: "Add export")

      {:ok, issue} =
        Pipeline.track_issue(project, %{number: 7, title: "Add export", body: "", url: "u"})

      {:ok, view, _html} = live(conn, ~p"/")
      assert has_element?(view, "#issue-#{issue.id}")

      {:ok, view, _html} = live(conn, ~p"/issues/#{issue.id}")
      assert has_element?(view, "#stage-track")
      refute has_element?(view, "#stop-button")
      refute has_element?(view, "#approve-button")

      for event <- ~w(stop approve) do
        assert render_hook(view, event, %{}) =~ "can only read"
      end

      assert render_hook(view, "request_changes", %{"review" => %{"feedback" => "x"}}) =~
               "can only read"

      assert render_hook(view, "request_pr_changes", %{"pr_changes" => %{"feedback" => "x"}}) =~
               "can only read"

      assert all_enqueued(worker: Factory.Workers.CommentWorker) == []

      assert Pipeline.get_issue!(issue.id).state == "planning"
      assert Fakes.GitHub.posted() == []

      assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/users")
    end
  end
end
