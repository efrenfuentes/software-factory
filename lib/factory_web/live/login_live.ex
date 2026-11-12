defmodule FactoryWeb.LoginLive do
  @moduledoc "Sign in with email and password. Accounts are created by an administrator."
  use FactoryWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    if Factory.Accounts.any_users?() do
      email = Phoenix.Flash.get(socket.assigns.flash, :email)
      form = to_form(%{"email" => email, "password" => ""}, as: :user)
      {:ok, assign(socket, page_title: "Sign in", form: form), temporary_assigns: [form: form]}
    else
      {:ok, redirect(socket, to: ~p"/setup")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.auth flash={@flash} title="Sign in">
      <.form for={@form} id="login-form" action={~p"/users/log-in"} method="post">
        <.input
          field={@form[:email]}
          type="email"
          label="Email"
          autocomplete="username"
          required
          phx-mounted={JS.focus()}
        />
        <.input
          field={@form[:password]}
          type="password"
          label="Password"
          autocomplete="current-password"
          required
        />
        <.button id="login-button" variant="primary" class="mt-2 w-full">Sign in</.button>
      </.form>
      <p class="mt-4 text-xs text-base-content/60">
        No account or a forgotten password? Ask an administrator of this factory.
      </p>
    </Layouts.auth>
    """
  end
end
