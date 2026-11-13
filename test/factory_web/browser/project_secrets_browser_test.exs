defmodule FactoryWeb.ProjectSecretsBrowserTest do
  @moduledoc """
  What a person's browser keeps in the secret forms after each submission.
  LiveView only patches what changed, and a field the server renders empty both
  before and after would keep what was typed in it: these tests type and submit
  in a real Chromium and read the fields' `value` and `checked` properties.
  """
  # A real server and a browser share the test's database connection.
  use FactoryWeb.ConnCase, async: false

  alias Factory.{AccountsFixtures, Fakes, Projects, Repo}
  alias Factory.Secrets.ProjectSecret
  alias FactoryWeb.Browser

  @moduletag :browser

  @value "s3cr3t-value"

  setup do
    Fakes.State.reset()
    user = AccountsFixtures.user_fixture(role: "admin")

    {:ok, project} =
      Projects.create_project(%{repo: "acme/app", app_type: "elixir", allowed_users: "m"})

    server =
      start_supervised!(
        {Bandit,
         plug: FactoryWeb.Endpoint, scheme: :http, ip: {127, 0, 0, 1}, port: 0, startup_log: false}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    base = "http://localhost:#{port}"
    browser = start_supervised!({Browser, Browser.executable()})

    Browser.visit(browser, base <> "/users/log-in")
    Browser.type(browser, "#login-form input[name='user[email]']", user.email)

    Browser.type(
      browser,
      "#login-form input[name='user[password]']",
      AccountsFixtures.valid_password()
    )

    Browser.click(browser, "#login-button")
    Browser.wait_until(browser, "location.pathname === '/' && document.readyState === 'complete'")

    Browser.visit(browser, base <> "/projects/#{project.id}/edit")
    Browser.connect_live(browser)

    %{browser: browser, project: project}
  end

  # The fields' live properties, not their attributes.
  defp fields(browser, form) do
    Browser.eval(browser, """
    (() => {
      const form = document.getElementById(#{Jason.encode!(form)});
      const name = form.querySelector("input[name='secret[name]']");
      return {
        name: name ? name.value : null,
        value: form.querySelector("textarea[name='secret[value]']").value,
        checked: form.querySelector("input[type=checkbox][name='secret[checks_only]']").checked
      };
    })()
    """)
  end

  defp submitted(browser, form, condition) do
    Browser.wait_until(browser, """
    (#{condition}) &&
      !document.getElementById(#{Jason.encode!(form)}).classList.contains("phx-submit-loading")
    """)
  end

  defp errors?(form), do: "!!document.querySelector('##{form} p.text-error')"

  test "the add and replace forms keep only what they should after each submission", %{
    browser: browser,
    project: project
  } do
    # A failed add: the name and the checkbox stay, the value goes.
    Browser.type(browser, "#secret-form input[name='secret[name]']", "PATH")
    Browser.type(browser, "#secret-form textarea[name='secret[value]']", @value)
    Browser.click(browser, "#secret-form input[type=checkbox][name='secret[checks_only]']")

    assert %{"name" => "PATH", "value" => @value, "checked" => true} =
             fields(browser, "secret-form")

    Browser.click(browser, "#add-secret")
    submitted(browser, "secret-form", errors?("secret-form"))
    assert fields(browser, "secret-form") == %{"name" => "PATH", "value" => "", "checked" => true}

    # A successful add: everything is cleared.
    Browser.eval(
      browser,
      "document.querySelector(\"#secret-form input[name='secret[name]']\").value = ''; true"
    )

    Browser.type(browser, "#secret-form input[name='secret[name]']", "API_KEY")
    Browser.type(browser, "#secret-form textarea[name='secret[value]']", @value)
    Browser.click(browser, "#add-secret")

    submitted(
      browser,
      "secret-form",
      "!!document.querySelector(\"#secrets > [id^='secrets-']:not(#secrets-empty)\")"
    )

    secret = Repo.get_by!(ProjectSecret, project_id: project.id, name: "API_KEY")
    assert secret.checks_only
    assert fields(browser, "secret-form") == %{"name" => "", "value" => "", "checked" => false}

    # A failed replacement: the value goes, the checkbox keeps what was sent.
    Browser.click(browser, "#replace-secret-#{secret.id}")
    Browser.wait_until(browser, "!!document.getElementById('replace-secret-form')")
    assert %{"value" => "", "checked" => true} = fields(browser, "replace-secret-form")

    Browser.type(browser, "#replace-secret-form textarea[name='secret[value]']", "7-chars")

    Browser.click(
      browser,
      "#replace-secret-form input[type=checkbox][name='secret[checks_only]']"
    )

    Browser.click(browser, "#save-replace")
    submitted(browser, "replace-secret-form", errors?("replace-secret-form"))

    assert fields(browser, "replace-secret-form") == %{
             "name" => nil,
             "value" => "",
             "checked" => false
           }

    assert Repo.reload!(secret) == secret

    refute Browser.eval(browser, "document.documentElement.outerHTML") =~ @value
  end
end
