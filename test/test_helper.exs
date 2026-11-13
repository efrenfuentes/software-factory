# The :browser tests need a Chromium (see FactoryWeb.Browser); without one they
# are excluded, and the run says so.
browser_exclusions =
  if FactoryWeb.Browser.executable() do
    []
  else
    IO.puts(
      :stderr,
      "No Chromium found (set FACTORY_TEST_BROWSER to one): excluding the :browser tests."
    )

    [:browser]
  end

ExUnit.start(exclude: browser_exclusions)
Ecto.Adapters.SQL.Sandbox.mode(Factory.Repo, :manual)
Factory.Fakes.State.start_link()
