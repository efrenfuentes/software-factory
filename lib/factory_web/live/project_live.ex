defmodule FactoryWeb.ProjectLive do
  @moduledoc "The repositories the factory works on and how: stack, people, and the model for each role."
  use FactoryWeb, :live_view
  alias Factory.{GitHub, Projects, Stacks}
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
    edit(socket, project, project.repo)
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

  def handle_event("save", %{"project" => params}, socket) do
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

  def handle_event("delete", _params, socket) do
    {:ok, _} = Projects.delete_project(socket.assigns.project)
    {:noreply, socket |> put_flash(:info, "Project removed.") |> push_navigate(to: ~p"/projects")}
  end

  defp model_options, do: Enum.map(Project.models(), &{Format.model(&1), &1})

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
    <Layouts.app flash={@flash}>
      <div class="flex items-end justify-between gap-4">
        <div>
          <h1 class="text-2xl font-semibold tracking-tight">Projects</h1>
          <p class="mt-1 text-sm text-base-content/60">Each project is one GitHub repository.</p>
        </div>
        <.button id="new-project" variant="primary" navigate={~p"/projects/new"}>
          <.icon name="hero-plus-micro" class="size-4" /> Add project
        </.button>
      </div>

      <div
        :if={@projects == []}
        id="no-projects"
        class="mt-8 rounded-xl border border-dashed border-base-300 bg-base-100 px-6 py-16 text-center"
      >
        <.icon name="hero-folder-plus" class="size-8 text-base-content/30" />
        <p class="mt-3 font-medium">No projects yet</p>
        <p class="mt-1 text-sm text-base-content/60">
          Add a repository to let the factory pick up its labelled issues.
        </p>
      </div>

      <ul id="projects" class="mt-6 grid gap-3 md:grid-cols-2">
        <li :for={project <- @projects} id={"project-#{project.id}"}>
          <.link
            navigate={~p"/projects/#{project.id}/edit"}
            class="block rounded-xl border border-base-300 bg-base-100 px-5 py-4 shadow-sm transition hover:-translate-y-0.5 hover:border-primary/50 hover:shadow"
          >
            <div class="flex items-center justify-between gap-3">
              <span class="truncate font-semibold">{project.repo}</span>
              <span class={[
                "rounded-full px-2 py-0.5 text-xs font-medium",
                if(project.enabled,
                  do: "bg-success/15 text-success",
                  else: "bg-base-300 text-base-content/60"
                )
              ]}>
                {if project.enabled, do: "Active", else: "Paused"}
              </span>
            </div>
            <div class="mt-1 text-sm text-base-content/60">
              {String.capitalize(project.app_type)} · label
              <code class="text-xs">{project.trigger_label}</code>
            </div>
            <dl class="mt-3 grid grid-cols-[auto_1fr] gap-x-4 gap-y-1 text-xs">
              <dt class="text-base-content/50">Planner</dt>
              <dd><.model_tag model={project.planner_model} effort={project.planner_effort} /></dd>
              <dt class="text-base-content/50">Reviewer</dt>
              <dd><.model_tag model={project.reviewer_model} effort={project.reviewer_effort} /></dd>
              <dt class="text-base-content/50">Developer</dt>
              <dd class="flex flex-wrap gap-x-3">
                <span>
                  hard <.model_tag model={project.dev_hard_model} effort={project.dev_hard_effort} />
                </span>
                <span>
                  medium
                  <.model_tag model={project.dev_medium_model} effort={project.dev_medium_effort} />
                </span>
                <span>
                  easy <.model_tag model={project.dev_easy_model} effort={project.dev_easy_effort} />
                </span>
              </dd>
            </dl>
          </.link>
        </li>
      </ul>
    </Layouts.app>
    """
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="mx-auto max-w-3xl">
        <.link
          navigate={~p"/projects"}
          class="inline-flex items-center gap-1 text-sm text-base-content/60 hover:text-base-content"
        >
          <.icon name="hero-arrow-left-micro" class="size-4" /> Projects
        </.link>
        <h1 class="mt-3 text-2xl font-semibold tracking-tight">{@page_title}</h1>

        <.form
          for={@form}
          id="project-form"
          phx-change="validate"
          phx-submit="save"
          class="mt-6 space-y-6"
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
            <p class="-mt-1 text-xs text-base-content/50">
              GitHub logins, comma separated. Comments from anyone else are shown to the agents as context only.
            </p>
            <.input
              field={@form[:enabled]}
              type="checkbox"
              label="Pick up issues from this repository"
            />
          </.section>

          <.section
            title="Models"
            hint="The Developer's model depends on the difficulty the Planner assigns."
          >
            <.role form={@form} label="Planner" prefix="planner" />
            <.role form={@form} label="Reviewer" prefix="reviewer" />
            <.role form={@form} label="Developer · hard" prefix="dev_hard" />
            <.role form={@form} label="Developer · medium" prefix="dev_medium" />
            <.role form={@form} label="Developer · easy" prefix="dev_easy" />
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
            <.input field={@form[:setup_cmd]} label="Setup" placeholder={placeholder(@form, :setup)} />
            <.input field={@form[:test_cmd]} label="Tests" placeholder={placeholder(@form, :test)} />
            <.input field={@form[:lint_cmd]} label="Lint" placeholder={placeholder(@form, :lint)} />
          </.section>

          <div class="flex items-center justify-between">
            <.button
              :if={@live_action == :edit}
              id="delete-project"
              type="button"
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
      </div>
    </Layouts.app>
    """
  end

  attr :title, :string, required: true
  attr :hint, :string, required: true
  slot :inner_block, required: true

  defp section(assigns) do
    ~H"""
    <fieldset class="rounded-xl border border-base-300 bg-base-100 px-5 py-4 shadow-sm">
      <legend class="sr-only">{@title}</legend>
      <h2 class="font-semibold">{@title}</h2>
      <p class="mb-3 text-sm text-base-content/60">{@hint}</p>
      {render_slot(@inner_block)}
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
    <div class="grid grid-cols-[1fr_8rem] gap-x-4 sm:grid-cols-[10rem_1fr_8rem] sm:items-center">
      <span class="col-span-2 text-sm font-medium sm:col-span-1">{@label}</span>
      <.input field={@model} type="select" options={model_options()} aria-label={"#{@label} model"} />
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
