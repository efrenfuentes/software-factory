defmodule FactoryWeb.SetupLive do
  @moduledoc """
  First run: creates the first administrator. It only works while the factory
  has no users at all.
  """
  use FactoryWeb, :live_view

  alias Factory.Accounts
  alias Factory.Accounts.User

  @impl true
  def mount(_params, _session, socket) do
    if Accounts.any_users?() do
      {:ok, redirect(socket, to: ~p"/users/log-in")}
    else
      {:ok,
       assign(socket,
         page_title: "Set up",
         form: to_form(Accounts.change_user(%User{role: "admin"}))
       )}
    end
  end

  @impl true
  def handle_event("validate", %{"user" => params}, socket) do
    changeset =
      %User{role: "admin"} |> Accounts.change_user(params) |> Map.put(:action, :validate)

    {:noreply, assign(socket, form: to_form(changeset))}
  end

  def handle_event("save", %{"user" => params}, socket) do
    case Accounts.create_first_admin(params) do
      {:ok, _user} ->
        {:noreply,
         socket
         |> put_flash(:info, "Administrator created. Sign in to continue.")
         |> redirect(to: ~p"/users/log-in")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}

      {:error, :already_set_up} ->
        {:noreply, redirect(socket, to: ~p"/users/log-in")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.auth
      flash={@flash}
      title="Create the first administrator"
      subtitle="This factory has no users yet. This account can add the others."
    >
      <.form for={@form} id="setup-form" phx-change="validate" phx-submit="save">
        <div class="grid gap-x-3 sm:grid-cols-2">
          <.input field={@form[:first_name]} label="First name" autocomplete="given-name" />
          <.input field={@form[:last_name]} label="Last name" autocomplete="family-name" />
        </div>
        <.input field={@form[:email]} type="email" label="Email" autocomplete="username" />
        <.input
          field={@form[:password]}
          type="password"
          label="Password"
          autocomplete="new-password"
        />
        <p class="-mt-1.5 text-xs text-base-content/60">At least 12 characters.</p>
        <.button
          id="setup-button"
          variant="primary"
          class="mt-4 w-full"
          phx-disable-with="Creating…"
        >
          Create administrator
        </.button>
      </.form>
    </Layouts.auth>
    """
  end
end
