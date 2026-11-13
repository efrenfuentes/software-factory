defmodule FactoryWeb.ProjectLive do
  @moduledoc "The repositories the factory works on and how: stack, people, and the model for each role."
  use FactoryWeb, :live_view
  alias Factory.{GitHub, Projects, Secrets, Stacks}
  alias Factory.Accounts.{Scope, User}
  alias Factory.Projects.Project
  alias FactoryWeb.Format

  @impl true
  def mount(_params, _session, socket), do: {:ok, socket}

  @impl true
  def handle_params(params, _uri, socket),
    do: {:noreply, apply_action(socket, socket.assigns.live_action, params)}

  defp apply_action(socket, :index, _params) do
    assign(socket,
      page_title: "Projects",
      projects: Projects.list_projects(),
      project: nil,
      form: nil
    )
  end

  defp apply_action(socket, :new, _params) do
    # Whoever runs the factory is the one person allowed to answer by default.
    login =
      case GitHub.impl().current_user() do
        {:ok, login} -> login
        _ -> ""
      end

    edit(socket, %Project{allowed_users: login}, "New project")
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    project = Projects.get_project!(id)

    socket
    |> edit(project, project.repo)
    |> assign(
      secrets_key?: Secrets.key_available?(),
      fingerprint: Secrets.current_fingerprint(),
      secret_form: secret_form(),
      replacing: nil,
      replace_form: nil
    )
    |> stream_secrets()
  end

  # Rows are rendered again (with the replace form open or closed) by resetting the stream.
  defp stream_secrets(socket) do
    stream(socket, :secrets, Secrets.list_secrets(socket.assigns.project), reset: true)
  end

  # The value a person typed never goes back to the page: the form keeps only the
  # name and the checkbox, with the errors.
  defp secret_form(changeset \\ Secrets.change_secret()) do
    params = if changeset.params, do: Map.put(changeset.params, "value", ""), else: nil
    to_form(%{changeset | params: params}, as: :secret)
  end

  defp edit(socket, project, title) do
    assign(socket,
      page_title: title,
      project: project,
      form: to_form(Projects.change_project(project))
    )
  end

  @impl true
  def handle_event("validate", %{"project" => params}, socket) do
    changeset =
      socket.assigns.project |> Projects.change_project(params) |> Map.put(:action, :validate)

    {:noreply, assign(socket, :form, to_form(changeset))}
  end

  # The routes keep others away from the form, but not from sending its events.
  def handle_event(event, params, socket)
      when event in ~w(save delete add_secret edit_secret cancel_replace replace_secret delete_secret) do
    if Scope.can?(socket.assigns.current_scope, :manage) and socket.assigns.form,
      do: manage(event, params, socket),
      else: {:noreply, put_flash(socket, :error, "Only administrators can change projects.")}
  end

  defp manage("save", %{"project" => params}, socket) do
    result =
      if socket.assigns.live_action == :new,
        do: Projects.create_project(params),
        else: Projects.update_project(socket.assigns.project, params)

    case result do
      {:ok, project} ->
        {:noreply,
         socket |> put_flash(:info, "#{project.repo} saved.") |> push_navigate(to: ~p"/projects")}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  defp manage("add_secret", params, socket) do
    with :edit <- socket.assigns.live_action,
         %{"secret" => %{} = attrs} <- params do
      case Secrets.create_secret(socket.assigns.project, attrs, socket.assigns.current_scope.user) do
        {:ok, secret} ->
          {:noreply,
           socket
           |> put_flash(:info, "Secret #{secret.name} added.")
           |> assign(:secret_form, secret_form())
           |> stream_secrets()}

        {:error, :no_key} ->
          {:noreply, no_key(socket)}

        {:error, changeset} ->
          {:noreply, assign(socket, :secret_form, secret_form(%{changeset | action: :insert}))}
      end
    else
      _ -> {:noreply, socket}
    end
  end

  defp manage("edit_secret", %{"id" => id}, %{assigns: %{live_action: :edit}} = socket) do
    case Secrets.get_secret(socket.assigns.project, id) do
      nil ->
        {:noreply, socket}

      secret ->
        {:noreply,
         socket
         |> assign(
           replacing: secret.id,
           replace_form: replace_form(Secrets.change_replace(secret))
         )
         |> stream_secrets()}
    end
  end

  defp manage("cancel_replace", _params, %{assigns: %{live_action: :edit}} = socket) do
    {:noreply, socket |> assign(replacing: nil, replace_form: nil) |> stream_secrets()}
  end

  defp manage("replace_secret", params, %{assigns: %{live_action: :edit}} = socket) do
    with %{"secret" => %{} = attrs} <- params,
         %{} = secret <- Secrets.get_secret(socket.assigns.project, socket.assigns.replacing) do
      case Secrets.replace_secret(secret, attrs, socket.assigns.current_scope.user) do
        {:ok, secret} ->
          {:noreply,
           socket
           |> put_flash(:info, "Secret #{secret.name} replaced.")
           |> assign(replacing: nil, replace_form: nil)
           |> stream_secrets()}

        {:error, :no_key} ->
          {:noreply, no_key(socket)}

        {:error, changeset} ->
          {:noreply,
           socket
           |> assign(:replace_form, replace_form(%{changeset | action: :update}))
           |> stream_secrets()}
      end
    else
      _ -> {:noreply, socket}
    end
  end

  defp manage("delete_secret", %{"id" => id}, %{assigns: %{live_action: :edit}} = socket) do
    case Secrets.get_secret(socket.assigns.project, id) do
      nil ->
        {:noreply, socket}

      secret ->
        {:ok, _} = Secrets.delete_secret(secret)

        replacing =
          if socket.assigns.replacing == secret.id, do: nil, else: socket.assigns.replacing

        {:noreply,
         socket
         |> put_flash(:info, "Secret #{secret.name} deleted.")
         |> assign(:replacing, replacing)
         |> stream_secrets()}
    end
  end

  defp manage(event, _params, socket)
       when event in ~w(edit_secret cancel_replace replace_secret delete_secret),
       do: {:noreply, socket}

  defp manage("delete", _params, socket) do
    {:ok, _} = Projects.delete_project(socket.assigns.project)
    {:noreply, socket |> put_flash(:info, "Project removed.") |> push_navigate(to: ~p"/projects")}
  end

  defp replace_form(changeset) do
    params = if changeset.params, do: Map.put(changeset.params, "value", ""), else: nil
    to_form(%{changeset | params: params}, as: :secret, id: "replace-secret")
  end

  defp no_key(socket),
    do: put_flash(socket, :error, "Set FACTORY_SECRETS_KEY to add or replace secrets.")

  defp model_options, do: Enum.map(Project.models(), &{Format.model(&1), &1})

  # Only the Reviewer can run on Codex.
  defp model_options("reviewer") do
    [
      {"Claude", model_options()},
      {"Codex", Enum.map(Project.codex_models(), &{Format.model(&1), &1})}
    ]
  end

  defp model_options(_role), do: model_options()

  # The stack's default command, shown where the override is left empty.
  defp placeholder(form, key) do
    type = form[:app_type].value

    cond do
      type not in Project.app_types() -> "Default for the application type"
      command = Stacks.defaults(type, "")[key] -> command
      true -> "None by default"
    end
  end

  @impl true
  def render(%{form: nil} = assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active={:projects}>
      <div class="flex flex-wrap items-end justify-between gap-3">
        <div>
          <h1 class="text-2xl font-semibold tracking-tight">Projects</h1>
          <p class="mt-1 text-sm text-base-content/60">Each project is one GitHub repository.</p>
        </div>
        <.button
          :if={Scope.can?(@current_scope, :manage)}
          id="new-project"
          variant="primary"
          navigate={~p"/projects/new"}
        >
          <.icon name="hero-plus-micro" class="size-4" /> Add project
        </.button>
      </div>

      <div
        :if={@projects == []}
        id="no-projects"
        class="mt-6 rounded-lg border border-dashed border-base-300 bg-base-100 px-5 py-14 text-center"
      >
        <.icon name="hero-folder-plus" class="size-8 text-base-content/30" />
        <p class="mt-3 font-medium">No projects yet</p>
        <p class="mx-auto mt-1 max-w-sm text-sm text-base-content/60">
          Add a repository to let the factory pick up its labelled issues.
        </p>
      </div>

      <ul id="projects" class="mt-5 grid gap-3 lg:grid-cols-2">
        <li :for={project <- @projects} id={"project-#{project.id}"}>
          <.link
            :if={Scope.can?(@current_scope, :manage)}
            navigate={~p"/projects/#{project.id}/edit"}
            class="group block h-full rounded-lg border border-base-300 bg-base-100 transition hover:border-base-content/40"
          >
            <.project_card project={project} />
          </.link>
          <div
            :if={not Scope.can?(@current_scope, :manage)}
            class="h-full rounded-lg border border-base-300 bg-base-100"
          >
            <.project_card project={project} />
          </div>
        </li>
      </ul>
    </Layouts.app>
    """
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active={:projects}>
      <div class="mx-auto max-w-4xl">
        <.link
          navigate={~p"/projects"}
          class="inline-flex min-h-8 items-center gap-1 rounded text-sm text-base-content/60 transition hover:text-base-content"
        >
          <.icon name="hero-arrow-left-micro" class="size-4" /> Projects
        </.link>
        <h1 class="mt-2 text-xl font-semibold tracking-tight [overflow-wrap:anywhere] sm:text-2xl">
          {@page_title}
        </h1>

        <.form
          for={@form}
          id="project-form"
          phx-change="validate"
          phx-submit="save"
          class="mt-5 overflow-hidden rounded-lg border border-base-300 bg-base-100"
        >
          <.section
            title="Repository"
            hint="The factory keeps its own clone and works on one branch per issue."
          >
            <div class="grid gap-x-4 sm:grid-cols-2">
              <.input field={@form[:repo]} label="GitHub repository" placeholder="owner/name" />
              <.input
                field={@form[:app_type]}
                type="select"
                label="Application type"
                prompt="Choose…"
                options={Enum.map(Project.app_types(), &{String.capitalize(&1), &1})}
              />
              <.input field={@form[:base_branch]} label="Base branch" />
              <.input field={@form[:trigger_label]} label="Trigger label" />
            </div>
            <.input
              field={@form[:allowed_users]}
              label="People who can answer and approve"
              placeholder="login, another-login"
            />
            <p class="-mt-1.5 mb-3 text-xs text-base-content/60">
              GitHub logins, comma separated. Comments from anyone else are shown to the agents as context only.
            </p>
            <.input
              field={@form[:enabled]}
              type="checkbox"
              label="Pick up issues from this repository"
            />
            <.input
              field={@form[:close_issue_on_merge]}
              type="checkbox"
              label="Close the issue when its pull request is merged"
            />
            <p class="-mt-1.5 text-xs text-base-content/60">
              When off, the issue stays open with the label <code class="font-mono">factory:merged</code>,
              for repositories that close issues at release.
            </p>
          </.section>

          <.section
            title="Models"
            hint="The Developer's model depends on the difficulty the Planner assigns. The Reviewer can also run on Codex, which reports tokens but no cost."
          >
            <.role form={@form} label="Planner" prefix="planner" />
            <.role form={@form} label="Reviewer" prefix="reviewer" />
            <.role form={@form} label="Developer, hard issues" prefix="dev_hard" />
            <.role form={@form} label="Developer, medium issues" prefix="dev_medium" />
            <.role form={@form} label="Developer, easy issues" prefix="dev_easy" />
          </.section>

          <.section
            title="Review"
            hint="After the last automatic round, a person has to allow each further one."
          >
            <div class="grid gap-x-4 sm:grid-cols-2">
              <.input
                field={@form[:max_plan_rounds]}
                type="number"
                min="0"
                max="10"
                label="Plan review rounds"
              />
              <.input
                field={@form[:max_pr_rounds]}
                type="number"
                min="1"
                max="10"
                label="Pull request review rounds"
              />
              <.input
                field={@form[:plan_approval]}
                type="select"
                label="A person approves the plan"
                options={[{"Only for hard issues", "hard"}, {"Always", "always"}, {"Never", "never"}]}
              />
              <.input
                field={@form[:max_budget_usd]}
                type="number"
                step="0.01"
                min="0"
                label="Budget per agent run (USD)"
                placeholder="No limit"
              />
            </div>
          </.section>

          <.section
            title="Checks"
            hint="Run after the Developer and before every review. Leave empty to use the stack's default."
          >
            <.input
              field={@form[:setup_cmd]}
              label="Setup"
              placeholder={placeholder(@form, :setup)}
              class="font-mono"
            />
            <.input
              field={@form[:test_cmd]}
              label="Tests"
              placeholder={placeholder(@form, :test)}
              class="font-mono"
            />
            <.input
              field={@form[:lint_cmd]}
              label="Lint"
              placeholder={placeholder(@form, :lint)}
              class="font-mono"
            />
          </.section>

          <div class="flex flex-col-reverse gap-2 bg-base-200/50 px-4 py-4 sm:flex-row sm:items-center sm:justify-between sm:px-6">
            <.button
              :if={@live_action == :edit}
              id="delete-project"
              type="button"
              variant="danger"
              phx-click="delete"
              data-confirm="Remove this project and the history of its issues?"
            >
              Remove project
            </.button>
            <span :if={@live_action == :new}></span>
            <.button id="save-project" variant="primary" phx-disable-with="Saving…">
              Save project
            </.button>
          </div>
        </.form>

        <.secrets_card
          :if={@live_action == :edit}
          streams={@streams}
          secrets_key?={@secrets_key?}
          fingerprint={@fingerprint}
          secret_form={@secret_form}
          replacing={@replacing}
          replace_form={@replace_form}
        />
      </div>
    </Layouts.app>
    """
  end

  attr :streams, :any, required: true
  attr :secrets_key?, :boolean, required: true
  attr :fingerprint, :string, default: nil
  attr :secret_form, :any, required: true
  attr :replacing, :any, default: nil
  attr :replace_form, :any, default: nil

  # Its own card, with forms of its own: a secret is saved on its own, never with the project.
  defp secrets_card(assigns) do
    ~H"""
    <div
      id="project-secrets"
      class="mt-6 overflow-hidden rounded-lg border border-base-300 bg-base-100"
    >
      <.section
        title="Secrets"
        hint="Environment variables for the checks and the Developer. Values are stored encrypted, never shown again, and replaced by [SECRET:NAME] in everything the factory writes."
      >
        <div
          :if={not @secrets_key?}
          id="secrets-key-missing"
          class="mb-4 flex gap-2.5 rounded-md border border-warning/40 bg-warning/10 px-3 py-2.5 text-sm"
        >
          <.icon name="hero-key-micro" class="mt-0.5 size-4 shrink-0 text-warning" />
          <div>
            <p class="font-medium">FACTORY_SECRETS_KEY is not set</p>
            <p class="mt-1 text-base-content/70">
              Generate a key with <code class="font-mono">openssl rand -base64 32</code>,
              add it to the service's environment file and restart. Until then secrets can be
              listed and deleted, but not added or replaced.
            </p>
          </div>
        </div>

        <ul
          id="secrets"
          phx-update="stream"
          class="divide-y divide-base-300 rounded-md border border-base-300"
        >
          <li id="secrets-empty" class="hidden px-3 py-4 text-sm text-base-content/60 only:block">
            No secrets yet.
          </li>
          <li
            :for={{dom_id, secret} <- @streams.secrets}
            id={dom_id}
            class="px-3 py-2.5 transition-colors hover:bg-base-200/40"
          >
            <div class="flex flex-wrap items-center justify-between gap-2">
              <div class="min-w-0">
                <div class="flex flex-wrap items-center gap-1.5">
                  <span class="font-mono text-sm font-medium [overflow-wrap:anywhere]">
                    {secret.name}
                  </span>
                  <span
                    :if={secret.checks_only}
                    class="rounded border border-base-300 px-1.5 py-px text-xs text-base-content/70"
                  >
                    only for the checks
                  </span>
                  <span
                    :if={@fingerprint && secret.key_fingerprint != @fingerprint}
                    id={"secret-#{secret.id}-other-key"}
                    class="rounded border border-warning/40 bg-warning/10 px-1.5 py-px text-xs text-warning"
                  >
                    saved with another key
                  </span>
                  <span
                    :if={Secrets.reserved?(secret.name)}
                    id={"secret-#{secret.id}-reserved"}
                    class="rounded border border-warning/40 bg-warning/10 px-1.5 py-px text-xs text-warning"
                  >
                    reserved name, not used
                  </span>
                </div>
                <p class="mt-0.5 text-xs text-base-content/60">
                  Changed {Format.time(secret.updated_at)} by {author(secret)}
                </p>
              </div>
              <div class="flex gap-2">
                <.button
                  id={"replace-secret-#{secret.id}"}
                  type="button"
                  phx-click="edit_secret"
                  phx-value-id={secret.id}
                  disabled={not @secrets_key?}
                >
                  Replace
                </.button>
                <.button
                  id={"delete-secret-#{secret.id}"}
                  type="button"
                  variant="danger"
                  phx-click="delete_secret"
                  phx-value-id={secret.id}
                  data-confirm={"Delete the secret #{secret.name}?"}
                >
                  Delete
                </.button>
              </div>
            </div>

            <.form
              :if={@replacing == secret.id and @replace_form}
              for={@replace_form}
              id="replace-secret-form"
              phx-submit="replace_secret"
              class="mt-3 rounded-md border border-base-300 bg-base-200/40 p-3"
            >
              <.input
                field={@replace_form[:value]}
                type="textarea"
                label="New value"
                rows="3"
                placeholder="Leave empty to keep the current value"
                autocomplete="off"
                class="font-mono"
              />
              <.input
                field={@replace_form[:checks_only]}
                type="checkbox"
                label="Only for the checks"
              />
              <div class="flex justify-end gap-2">
                <.button id="cancel-replace" type="button" phx-click="cancel_replace">
                  Cancel
                </.button>
                <.button
                  id="save-replace"
                  variant="primary"
                  disabled={not @secrets_key?}
                  phx-disable-with="Saving…"
                >
                  Save
                </.button>
              </div>
            </.form>
          </li>
        </ul>

        <.form for={@secret_form} id="secret-form" phx-submit="add_secret" class="mt-4">
          <fieldset disabled={not @secrets_key?} class="disabled:opacity-60">
            <.input
              field={@secret_form[:name]}
              label="Name"
              placeholder="API_KEY"
              autocomplete="off"
              class="font-mono"
            />
            <.input
              field={@secret_form[:value]}
              type="textarea"
              label="Value"
              rows="3"
              autocomplete="off"
              class="font-mono"
            />
            <.input
              field={@secret_form[:checks_only]}
              type="checkbox"
              label="Only for the checks"
            />
            <p class="-mt-1.5 mb-3 text-xs text-base-content/60">
              The checks get every secret; the Developer only those not marked.
            </p>
            <div class="flex justify-end">
              <.button id="add-secret" variant="primary" phx-disable-with="Adding…">
                <.icon name="hero-plus-micro" class="size-4" /> Add secret
              </.button>
            </div>
          </fieldset>
        </.form>
      </.section>
    </div>
    """
  end

  defp author(%{updated_by: %User{} = user}), do: User.full_name(user)
  defp author(_secret), do: "a removed user"

  attr :project, Project, required: true

  defp project_card(assigns) do
    ~H"""
    <div class="flex items-start justify-between gap-3 px-4 pt-4">
      <div class="min-w-0">
        <div class="truncate font-mono text-sm font-medium transition group-hover:text-primary">
          {@project.repo}
        </div>
        <div class="mt-1 flex flex-wrap items-center gap-x-2 gap-y-1 text-xs text-base-content/60">
          <span>{String.capitalize(@project.app_type)}</span>
          <span class="font-mono">{@project.base_branch}</span>
          <span class="rounded border border-base-300 px-1.5 py-px font-mono">
            {@project.trigger_label}
          </span>
        </div>
      </div>
      <span class={[
        "inline-flex shrink-0 items-center gap-1.5 rounded-full border px-2 py-0.5 text-xs font-medium",
        if(@project.enabled,
          do: "border-success/40 bg-success/10 text-success",
          else: "border-base-300 bg-base-200 text-base-content/60"
        )
      ]}>
        <span class="size-1.5 rounded-full bg-current" />
        {if @project.enabled, do: "Active", else: "Paused"}
      </span>
    </div>
    <dl class="mt-4 grid grid-cols-[auto_minmax(0,1fr)] gap-x-4 gap-y-1.5 border-t border-base-300 px-4 py-3 text-xs">
      <dt class="text-base-content/50">Planner</dt>
      <dd><.model_tag model={@project.planner_model} effort={@project.planner_effort} /></dd>
      <dt class="text-base-content/50">Reviewer</dt>
      <dd><.model_tag model={@project.reviewer_model} effort={@project.reviewer_effort} /></dd>
      <dt class="text-base-content/50">Developer</dt>
      <dd class="grid gap-1">
        <span :for={
          {level, model, effort} <- [
            {"hard", @project.dev_hard_model, @project.dev_hard_effort},
            {"medium", @project.dev_medium_model, @project.dev_medium_effort},
            {"easy", @project.dev_easy_model, @project.dev_easy_effort}
          ]
        }>
          <.model_tag model={model} effort={effort} />
          <span class="text-base-content/40">for {level}</span>
        </span>
      </dd>
    </dl>
    """
  end

  attr :title, :string, required: true
  attr :hint, :string, required: true
  slot :inner_block, required: true

  # Title and explanation on the left, fields on the right; stacked on small screens.
  defp section(assigns) do
    ~H"""
    <fieldset class="grid gap-x-8 gap-y-3 border-b border-base-300 px-4 py-5 sm:px-6 md:grid-cols-[14rem_minmax(0,1fr)]">
      <legend class="sr-only">{@title}</legend>
      <div>
        <h2 class="font-semibold">{@title}</h2>
        <p class="mt-1 text-sm text-base-content/60">{@hint}</p>
      </div>
      <div class="min-w-0">{render_slot(@inner_block)}</div>
    </fieldset>
    """
  end

  attr :form, :any, required: true
  attr :label, :string, required: true
  attr :prefix, :string, required: true

  defp role(assigns) do
    assigns =
      assign(assigns,
        model: assigns.form[String.to_existing_atom(assigns.prefix <> "_model")],
        effort: assigns.form[String.to_existing_atom(assigns.prefix <> "_effort")]
      )

    ~H"""
    <div class="grid grid-cols-[minmax(0,1fr)_7rem] gap-x-3">
      <span class="col-span-2 mb-1.5 text-sm font-medium">{@label}</span>
      <.input
        field={@model}
        type="select"
        options={model_options(@prefix)}
        aria-label={"#{@label} model"}
      />
      <.input
        field={@effort}
        type="select"
        options={Project.efforts()}
        aria-label={"#{@label} effort"}
      />
    </div>
    """
  end
end
