defmodule FactoryWeb.UserSessionController do
  use FactoryWeb, :controller

  alias Factory.Accounts
  alias FactoryWeb.UserAuth

  def create(conn, %{"user" => %{"email" => email, "password" => password}}) do
    if user = Accounts.authenticate(email, password) do
      UserAuth.log_in_user(conn, user)
    else
      # The same message for a wrong password, an unknown email and a deactivated account.
      conn
      |> put_flash(:error, "The email or password is not correct.")
      |> put_flash(:email, String.slice(email, 0, 160))
      |> redirect(to: ~p"/users/log-in")
    end
  end

  def delete(conn, _params), do: UserAuth.log_out_user(conn)
end
