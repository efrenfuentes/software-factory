defmodule FactoryWeb.ProjectSecretsLiveTest do
  # Changes the application's configuration (the key, the passthrough) and the log level.
  use FactoryWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import ExUnit.CaptureLog
  import Ecto.Query

  alias Factory.{Fakes, Projects, Repo, Secrets}
  alias Factory.Secrets.ProjectSecret

  @value "s3cr3t-value"

  setup :sign_in

  setup do
    Fakes.State.reset()
    key = Application.get_env(:factory, :secrets_key)
    passthrough = Application.get_env(:factory, :env_passthrough)

    on_exit(fn ->
      Application.put_env(:factory, :secrets_key, key)

      if passthrough,
        do: Application.put_env(:factory, :env_passthrough, passthrough),
        else: Application.delete_env(:factory, :env_passthrough)
    end)

    {:ok, project} =
      Projects.create_project(%{repo: "acme/app", app_type: "elixir", allowed_users: "m"})

    %{project: project}
  end

  defp open(conn, project) do
    {:ok, view, _html} = live(conn, ~p"/projects/#{project.id}/edit")
    view
  end

  defp add(view, attrs) do
    view |> form("#secret-form", secret: attrs) |> render_submit()
  end

  defp leaked?(view, value) do
    render(view) =~ value or inspect(:sys.get_state(view.pid), limit: :infinity) =~ value
  end

  defp row(project, name), do: Repo.get_by!(ProjectSecret, project_id: project.id, name: name)

  test "a secret is added, replaced and deleted without its value ever showing", %{
    conn: conn,
    project: project,
    user: user
  } do
    view = open(conn, project)
    assert has_element?(view, "#project-secrets")
    assert has_element?(view, "#secrets-empty")

    add(view, %{name: "API_KEY", value: @value})

    secret = row(project, "API_KEY")
    assert has_element?(view, "#secrets-#{secret.id}", "API_KEY")
    assert has_element?(view, "#secrets-#{secret.id}", user.first_name)
    assert has_element?(view, "#secret-form textarea[name='secret[value]']")
    refute has_element?(view, "#secret-form input[name='secret[name]'][value='API_KEY']")
    refute leaked?(view, @value)
    refute secret.encrypted_value =~ @value

    assert Factory.Secrets.Cipher.decrypt(
             secret.encrypted_value,
             Factory.Secrets.Cipher.aad(project.id, "API_KEY")
           ) == {:ok, @value}

    # The same name again is refused; the name stays, the value does not.
    html = add(view, %{name: "API_KEY", value: @value})
    assert html =~ "already exists — use Replace"
    assert has_element?(view, "#secret-form input[name='secret[name]'][value='API_KEY']")
    refute leaked?(view, @value)

    # Replace with an empty value only changes the checkbox, the date and the author.
    Repo.update_all(ProjectSecret,
      set: [updated_at: ~U[2020-01-01 00:00:00Z], updated_by_id: nil]
    )

    view |> element("#replace-secret-#{secret.id}") |> render_click()
    assert has_element?(view, "#replace-secret-form")

    view
    |> form("#replace-secret-form", secret: %{value: "", checks_only: "true"})
    |> render_submit()

    replaced = row(project, "API_KEY")
    assert replaced.checks_only
    assert replaced.encrypted_value == secret.encrypted_value
    assert replaced.updated_by_id == user.id
    assert DateTime.compare(replaced.updated_at, ~U[2020-01-01 00:00:00Z]) == :gt
    refute has_element?(view, "#replace-secret-form")
    assert has_element?(view, "#secrets-#{secret.id}", "only for the checks")

    assert has_element?(view, "#delete-secret-#{secret.id}[data-confirm]")
    view |> element("#delete-secret-#{secret.id}") |> render_click()
    refute has_element?(view, "#secrets-#{secret.id}")
    assert Secrets.list_secrets(project) == []
  end

  test "a failed submission keeps the name and checkbox, with errors, but not the value", %{
    conn: conn,
    project: project
  } do
    view = open(conn, project)

    html = add(view, %{name: "PATH", value: @value, checks_only: "true"})
    assert html =~ "is reserved"
    assert has_element?(view, "#secret-form input[name='secret[name]'][value='PATH']")
    assert has_element?(view, "#secret-form input[name='secret[checks_only]'][checked]")
    refute leaked?(view, @value)

    html = add(view, %{name: "API_KEY", value: "1234567"})
    assert html =~ "should be at least 8 character"
    refute leaked?(view, "1234567")
    assert Secrets.list_secrets(project) == []
  end

  test "the page for a new project has no secrets", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/projects/new")
    refute has_element?(view, "#project-secrets")
  end

  test "without a key secrets are listed and deleted, but not added or replaced", %{
    conn: conn,
    project: project,
    user: user
  } do
    {:ok, secret} =
      Secrets.create_secret(project, %{"name" => "API_KEY", "value" => @value}, user)

    Application.put_env(:factory, :secrets_key, nil)
    view = open(conn, project)

    assert has_element?(view, "#secrets-key-missing")
    assert has_element?(view, "#secret-form fieldset[disabled]")
    assert has_element?(view, "#replace-secret-#{secret.id}[disabled]")

    assert render_hook(view, "add_secret", %{"secret" => %{"name" => "OTHER", "value" => @value}}) =~
             "FACTORY_SECRETS_KEY"

    render_hook(view, "edit_secret", %{"id" => to_string(secret.id)})

    render_hook(view, "replace_secret", %{"secret" => %{"value" => "another-value-1"}})

    assert row(project, "API_KEY").encrypted_value ==
             Repo.get!(ProjectSecret, secret.id).encrypted_value

    assert [%{name: "API_KEY"}] = Secrets.list_secrets(project)

    view |> element("#delete-secret-#{secret.id}") |> render_click()
    assert Secrets.list_secrets(project) == []
  end

  test "rows stored with another key or under a now reserved name are marked", %{
    conn: conn,
    project: project,
    user: user
  } do
    {:ok, other} = Secrets.create_secret(project, %{"name" => "OLD_KEY", "value" => @value}, user)

    {:ok, passed} =
      Secrets.create_secret(project, %{"name" => "GH_TOKEN", "value" => @value}, user)

    Repo.update_all(from(s in ProjectSecret, where: s.id == ^other.id),
      set: [key_fingerprint: "0000"]
    )

    Application.put_env(:factory, :env_passthrough, ["GH_TOKEN"])

    view = open(conn, project)
    assert has_element?(view, "#secret-#{other.id}-other-key")
    refute has_element?(view, "#secret-#{passed.id}-other-key")
    assert has_element?(view, "#secret-#{passed.id}-reserved")
    refute has_element?(view, "#secret-#{other.id}-reserved")
  end

  describe "logs" do
    test "the values sent to the secret events never reach the log", %{
      conn: conn,
      project: project,
      user: user
    } do
      {:ok, secret} =
        Secrets.create_secret(project, %{"name" => "API_KEY", "value" => "first-value-1"}, user)

      level = Logger.level()
      Logger.configure(level: :debug)
      on_exit(fn -> Logger.configure(level: level) end)

      log =
        capture_log([level: :debug], fn ->
          view = open(conn, project)
          add(view, %{name: "NEW_ONE", value: "valid-value-1"})
          add(view, %{name: "PATH", value: "invalid-name-value"})
          view |> element("#replace-secret-#{secret.id}") |> render_click()

          view
          |> form("#replace-secret-form", secret: %{value: "replaced-value-1"})
          |> render_submit()

          view |> element("#replace-secret-#{secret.id}") |> render_click()
          view |> form("#replace-secret-form", secret: %{value: "7-chars"}) |> render_submit()
        end)

      assert log =~ "HANDLE EVENT"

      for value <- ~w(valid-value-1 invalid-name-value replaced-value-1 7-chars) do
        refute log =~ value
      end

      refute inspect(Phoenix.Logger.filter_values(%{"secret" => %{"value" => "x-value-9"}})) =~
               "x-value-9"
    end
  end
end
