defmodule FactoryWeb.UserAuth do
  @moduledoc """
  Signs people in and out, and guards pages by role.

  The browser session holds a random token; the matching row in the database is
  the session. Removing the row signs that browser out, also for LiveViews that
  are already open.
  """
  use FactoryWeb, :verified_routes

  import Plug.Conn
  import Phoenix.Controller

  alias Factory.Accounts
  alias Factory.Accounts.Scope

  ## Plugs

  def fetch_current_scope(conn, _opts) do
    user = Accounts.get_user_by_session(get_session(conn, :user_token))
    assign(conn, :current_scope, Scope.for_user(user))
  end

  def log_in_user(conn, user) do
    token = Accounts.create_session(user)
    return_to = get_session(conn, :user_return_to)

    conn
    # A fresh session id, so one fixed before signing in cannot be reused.
    |> configure_session(renew: true)
    |> clear_session()
    |> put_session(:user_token, token)
    |> put_session(:live_socket_id, socket_id(token))
    |> redirect(to: return_to || ~p"/")
  end

  def log_out_user(conn) do
    token = get_session(conn, :user_token)
    Accounts.delete_session(token)
    if token, do: disconnect([token])

    conn
    |> configure_session(renew: true)
    |> clear_session()
    |> redirect(to: ~p"/users/log-in")
  end

  @doc "Closes the open LiveViews of sessions that were ended."
  def disconnect(tokens) do
    for token <- tokens,
        do: FactoryWeb.Endpoint.broadcast(socket_id(token), "disconnect", %{})

    :ok
  end

  defp socket_id(token), do: "users_sessions:#{Base.url_encode64(token)}"

  ## LiveView hooks, used with `live_session ... on_mount: {FactoryWeb.UserAuth, hook}`

  def on_mount(:require_authenticated, _params, session, socket) do
    socket = mount_scope(socket, session)

    if socket.assigns.current_scope do
      {:cont, socket}
    else
      {:halt, Phoenix.LiveView.redirect(socket, to: sign_in_path())}
    end
  end

  def on_mount(:require_admin, _params, session, socket) do
    socket = mount_scope(socket, session)

    cond do
      is_nil(socket.assigns.current_scope) ->
        {:halt, Phoenix.LiveView.redirect(socket, to: sign_in_path())}

      Scope.can?(socket.assigns.current_scope, :manage) ->
        {:cont, socket}

      true ->
        {:halt,
         socket
         |> Phoenix.LiveView.put_flash(:error, "Only administrators can open that page.")
         |> Phoenix.LiveView.redirect(to: ~p"/")}
    end
  end

  # The sign-in and first-run pages: someone already signed in goes to the app.
  def on_mount(:redirect_if_authenticated, _params, session, socket) do
    socket = mount_scope(socket, session)

    if socket.assigns.current_scope,
      do: {:halt, Phoenix.LiveView.redirect(socket, to: ~p"/")},
      else: {:cont, socket}
  end

  defp mount_scope(socket, session) do
    Phoenix.Component.assign_new(socket, :current_scope, fn ->
      session["user_token"] |> Accounts.get_user_by_session() |> Scope.for_user()
    end)
  end

  # A new installation has nobody to sign in as: send people to create the first account.
  defp sign_in_path, do: if(Accounts.any_users?(), do: ~p"/users/log-in", else: ~p"/setup")

  ## Controller plugs

  def require_authenticated(conn, _opts) do
    if conn.assigns.current_scope do
      conn
    else
      conn
      |> maybe_store_return_to()
      |> redirect(to: sign_in_path())
      |> halt()
    end
  end

  defp maybe_store_return_to(%{method: "GET"} = conn),
    do: put_session(conn, :user_return_to, current_path(conn))

  defp maybe_store_return_to(conn), do: conn
end
