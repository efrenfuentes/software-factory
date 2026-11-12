defmodule FactoryWeb.AccountLive do
  @moduledoc "A person's own account: who they are signed in as, their password, and signing out."
  use FactoryWeb, :live_view

  alias Factory.Accounts
  alias Factory.Accounts.User
  alias FactoryWeb.UserAuth

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Your account",
       form: password_form(socket.assigns.current_scope.user)
     )}
  end

  defp password_form(user, params \\ %{}, action \\ nil) do
    user |> Accounts.change_password(params) |> Map.put(:action, action) |> to_form(as: :user)
  end

  @impl true
  def handle_event("validate", %{"user" => params}, socket) do
    {:noreply,
     assign(socket, form: password_form(socket.assigns.current_scope.user, params, :validate))}
  end

  def handle_event("save", %{"user" => params}, socket) do
    user = socket.assigns.current_scope.user

    case Accounts.update_password(user, params["current_password"], params) do
      {:ok, {_user, ended}} ->
        UserAuth.disconnect(ended)

        {:noreply,
         socket
         |> put_flash(:info, "Password changed. Sign in again with the new one.")
         |> redirect(to: ~p"/users/log-in")}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(Map.put(changeset, :action, :insert), as: :user))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active={:account}>
      <div class="mx-auto max-w-xl">
        <h1 class="text-2xl font-semibold tracking-tight">Your account</h1>

        <div class="mt-5 flex flex-wrap items-center justify-between gap-4 rounded-lg border border-base-300 bg-base-100 p-4">
          <div class="flex min-w-0 items-center gap-3">
            <span class="grid size-11 shrink-0 place-items-center rounded-full border border-base-300 bg-base-200 font-mono text-sm font-medium">
              {User.initials(@current_scope.user)}
            </span>
            <div class="min-w-0">
              <div id="account-name" class="truncate font-medium">
                {User.full_name(@current_scope.user)}
              </div>
              <div class="truncate font-mono text-xs text-base-content/60">
                {@current_scope.user.email}
              </div>
            </div>
          </div>
          <div class="flex items-center gap-3">
            <.role_badge role={@current_scope.user.role} />
            <.button id="log-out" href={~p"/users/log-out"} method="delete">
              <.icon name="hero-arrow-right-start-on-rectangle-micro" class="size-4" /> Sign out
            </.button>
          </div>
        </div>

        <.form
          for={@form}
          id="password-form"
          phx-change="validate"
          phx-submit="save"
          class="mt-3 rounded-lg border border-base-300 bg-base-100 p-4"
        >
          <h2 class="font-semibold">Change password</h2>
          <p class="mb-4 mt-1 text-sm text-base-content/60">
            Changing it signs you out everywhere, including here.
          </p>
          <.input
            field={@form[:current_password]}
            type="password"
            label="Current password"
            autocomplete="current-password"
            value=""
          />
          <.input
            field={@form[:password]}
            type="password"
            label="New password"
            autocomplete="new-password"
          />
          <.input
            field={@form[:password_confirmation]}
            type="password"
            label="New password again"
            autocomplete="new-password"
          />
          <div class="mt-2 flex justify-end">
            <.button id="save-password" variant="primary" phx-disable-with="Saving…">
              Change password
            </.button>
          </div>
        </.form>
      </div>
    </Layouts.app>
    """
  end
end
