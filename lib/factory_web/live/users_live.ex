defmodule FactoryWeb.UsersLive do
  @moduledoc "Administrators manage who can sign in and what each person may do."
  use FactoryWeb, :live_view

  alias Factory.Accounts
  alias Factory.Accounts.User
  alias FactoryWeb.UserAuth

  @impl true
  def mount(_params, _session, socket), do: {:ok, socket}

  @impl true
  def handle_params(params, _uri, socket),
    do: {:noreply, apply_action(socket, socket.assigns.live_action, params)}

  defp apply_action(socket, :index, _params) do
    assign(socket, page_title: "Users", users: Accounts.list_users(), user: nil, form: nil)
  end

  defp apply_action(socket, :new, _params), do: edit(socket, %User{}, "New user")

  defp apply_action(socket, :edit, %{"id" => id}) do
    user = Accounts.get_user!(id)
    edit(socket, user, User.full_name(user))
  end

  defp edit(socket, user, title) do
    assign(socket,
      page_title: title,
      user: user,
      last_admin?: Accounts.last_admin?(user),
      form: to_form(Accounts.change_user(user))
    )
  end

  @impl true
  def handle_event("validate", %{"user" => params}, socket) do
    changeset =
      socket.assigns.user |> Accounts.change_user(params) |> Map.put(:action, :validate)

    {:noreply, assign(socket, form: to_form(changeset))}
  end

  def handle_event("save", %{"user" => params}, socket) do
    result =
      if socket.assigns.live_action == :new do
        with {:ok, user} <- Accounts.create_user(params), do: {:ok, {user, []}}
      else
        Accounts.update_user(socket.assigns.user, params)
      end

    case result do
      {:ok, {user, ended_sessions}} ->
        UserAuth.disconnect(ended_sessions)

        {:noreply,
         socket
         |> put_flash(:info, "#{User.full_name(user)} saved.")
         |> push_navigate(to: ~p"/users")}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp role_options do
    [
      {"Administrator: everything, including projects and users", "admin"},
      {"Operator: approves, asks for changes, retries and stops", "operator"},
      {"Read only: sees everything, changes nothing", "viewer"}
    ]
  end

  @impl true
  def render(%{form: nil} = assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active={:users}>
      <div class="flex flex-wrap items-end justify-between gap-3">
        <div>
          <h1 class="text-2xl font-semibold tracking-tight">Users</h1>
          <p class="mt-1 max-w-prose text-sm text-base-content/60">
            People are added here; nobody can register by themselves.
          </p>
        </div>
        <.button id="new-user" variant="primary" navigate={~p"/users/new"}>
          <.icon name="hero-plus-micro" class="size-4" /> Add user
        </.button>
      </div>

      <ul id="users" class="mt-5 overflow-hidden rounded-lg border border-base-300 bg-base-100">
        <li
          :for={user <- @users}
          id={"user-#{user.id}"}
          class="border-b border-base-300 last:border-b-0"
        >
          <.link
            navigate={~p"/users/#{user.id}/edit"}
            class="group flex items-center gap-3 px-4 py-3 transition hover:bg-base-200/60"
          >
            <span class={[
              "grid size-9 shrink-0 place-items-center rounded-full border border-base-300 bg-base-200 font-mono text-xs font-medium",
              not user.active && "opacity-50"
            ]}>
              {User.initials(user)}
            </span>
            <div class="min-w-0 flex-1">
              <div class={[
                "truncate font-medium transition group-hover:text-primary",
                not user.active && "text-base-content/50"
              ]}>
                {User.full_name(user)}
                <span
                  :if={user.id == @current_scope.user.id}
                  class="font-normal text-base-content/50"
                >
                  (you)
                </span>
              </div>
              <div class="truncate font-mono text-xs text-base-content/60">{user.email}</div>
            </div>
            <span
              :if={not user.active}
              class="shrink-0 rounded border border-base-300 px-1.5 py-px font-mono text-[11px] text-base-content/60"
            >
              deactivated
            </span>
            <.role_badge role={user.role} />
            <.icon
              name="hero-chevron-right-micro"
              class="hidden size-4 text-base-content/30 sm:block"
            />
          </.link>
        </li>
      </ul>
    </Layouts.app>
    """
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active={:users}>
      <div class="mx-auto max-w-xl">
        <.link
          navigate={~p"/users"}
          class="inline-flex min-h-8 items-center gap-1 rounded text-sm text-base-content/60 transition hover:text-base-content"
        >
          <.icon name="hero-arrow-left-micro" class="size-4" /> Users
        </.link>
        <h1 class="mt-2 text-xl font-semibold tracking-tight [overflow-wrap:anywhere] sm:text-2xl">
          {@page_title}
        </h1>

        <.form
          for={@form}
          id="user-form"
          phx-change="validate"
          phx-submit="save"
          class="mt-5 rounded-lg border border-base-300 bg-base-100 p-4 sm:p-5"
        >
          <div class="grid gap-x-4 sm:grid-cols-2">
            <.input field={@form[:first_name]} label="First name" />
            <.input field={@form[:last_name]} label="Last name" />
          </div>
          <.input field={@form[:email]} type="email" label="Email" autocomplete="off" />
          <.input
            field={@form[:role]}
            type="select"
            label="Access"
            options={role_options()}
            disabled={@last_admin?}
          />
          <p :if={@last_admin?} id="last-admin-note" class="-mt-1.5 mb-3 text-xs text-base-content/60">
            This is the only active administrator, so its access cannot change. Make someone else an administrator first.
          </p>
          <.input
            field={@form[:password]}
            type="password"
            label={if @live_action == :new, do: "Password", else: "New password"}
            autocomplete="new-password"
            value=""
          />
          <p class="-mt-1.5 mb-3 text-xs text-base-content/60">
            {if @live_action == :new,
              do: "At least 12 characters. Give it to the person; they can change it afterwards.",
              else: "Leave empty to keep the current one. At least 12 characters."}
          </p>
          <.input
            :if={@live_action == :edit}
            field={@form[:active]}
            type="checkbox"
            label="Can sign in"
            disabled={@last_admin?}
          />
          <p :if={@live_action == :edit} class="-mt-1.5 text-xs text-base-content/60">
            Changing the access, the password or this box signs the person out everywhere.
          </p>
          <div class="mt-4 flex justify-end">
            <.button id="save-user" variant="primary" phx-disable-with="Saving…">
              Save user
            </.button>
          </div>
        </.form>
      </div>
    </Layouts.app>
    """
  end
end
