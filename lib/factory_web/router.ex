defmodule FactoryWeb.Router do
  use FactoryWeb, :router

  import FactoryWeb.UserAuth, only: [fetch_current_scope: 2, require_authenticated: 2]

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {FactoryWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_scope
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  # Signing in, and the first-run page that creates the first administrator.
  scope "/", FactoryWeb do
    pipe_through :browser

    live_session :signed_out, on_mount: {FactoryWeb.UserAuth, :redirect_if_authenticated} do
      live "/users/log-in", LoginLive
      live "/setup", SetupLive
    end

    post "/users/log-in", UserSessionController, :create
    delete "/users/log-out", UserSessionController, :delete
  end

  # Everyone signed in can read; what they may change is checked in each page.
  scope "/", FactoryWeb do
    pipe_through [:browser, :require_authenticated]

    live_session :signed_in, on_mount: {FactoryWeb.UserAuth, :require_authenticated} do
      live "/", DashboardLive
      live "/issues/:id", IssueLive
      live "/projects", ProjectLive, :index
      live "/account", AccountLive
    end

    live_session :administrators, on_mount: {FactoryWeb.UserAuth, :require_admin} do
      live "/projects/new", ProjectLive, :new
      live "/projects/:id/edit", ProjectLive, :edit
      live "/users", UsersLive, :index
      live "/users/new", UsersLive, :new
      live "/users/:id/edit", UsersLive, :edit
    end
  end

  # Other scopes may use custom stacks.
  # scope "/api", FactoryWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:factory, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: FactoryWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
