defmodule FactoryWeb.DashboardLive do
  @moduledoc "Every issue in the factory: where it is, how long each stage took and which model ran it."
  use FactoryWeb, :live_view
  alias Factory.Pipeline
  alias Factory.Pipeline.Issue
  alias FactoryWeb.Format

  @phases [
    {"Plan", "planning"},
    {"Plan review", "plan_review"},
    {"Develop", "developing"},
    {"PR review", "pr_review"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Pipeline.subscribe()
      :timer.send_interval(1000, :tick)
    end

    {:ok,
     socket |> assign(page_title: "Issues", now: DateTime.utc_now(), phases: @phases) |> load()}
  end

  @impl true
  def handle_info(:tick, socket), do: {:noreply, assign(socket, :now, DateTime.utc_now())}
  def handle_info({:issue_updated, _id}, socket), do: {:noreply, load(socket)}

  defp load(socket) do
    rows =
      Enum.sort_by(
        Pipeline.overview(),
        &{order(&1.issue.state), -DateTime.to_unix(&1.issue.state_entered_at)}
      )

    issues = Enum.map(rows, & &1.issue)

    assign(socket,
      rows: rows,
      projects?: Factory.Projects.list_projects() != [],
      working: Enum.count(issues, &Issue.active?/1),
      waiting: Enum.count(issues, &(Format.tone(&1.state) in [:person, :failed])),
      done: Enum.count(issues, &(&1.state == "done")),
      cost:
        issues
        |> Enum.map(& &1.cost_usd)
        |> Enum.reject(&is_nil/1)
        |> Enum.reduce(Decimal.new(0), &Decimal.add/2)
    )
  end

  # Issues that need a person come first, then the ones being worked on.
  defp order(state) do
    case Format.tone(state) do
      :failed -> 0
      :person -> 0
      :working -> 1
      _ -> 2
    end
  end

  defp last_run(runs, stage), do: runs |> Enum.filter(&(&1.stage == stage)) |> List.last()

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="flex flex-wrap items-end justify-between gap-4">
        <div>
          <h1 class="text-2xl font-semibold tracking-tight">Issues</h1>
          <p class="mt-1 text-sm text-base-content/60">
            GitHub is checked every minute for labelled issues, answers and merged pull requests.
          </p>
        </div>
      </div>

      <dl class="mt-6 grid grid-cols-2 gap-3 lg:grid-cols-4">
        <.tile id="stat-working" label="Being worked on" value={@working} tone="text-info" />
        <.tile id="stat-waiting" label="Waiting on you" value={@waiting} tone="text-warning" />
        <.tile id="stat-done" label="Merged" value={@done} tone="text-success" />
        <.tile id="stat-cost" label="Total cost" value={Format.cost(@cost)} tone="" />
      </dl>

      <div
        :if={@rows == []}
        id="empty-state"
        class="mt-8 rounded-xl border border-dashed border-base-300 bg-base-100 px-6 py-16 text-center"
      >
        <.icon name="hero-inbox" class="size-8 text-base-content/30" />
        <p class="mt-3 font-medium">No issues yet</p>
        <p :if={@projects?} class="mt-1 text-sm text-base-content/60">
          Add a project's trigger label to a GitHub issue and it will show up here within a minute.
        </p>
        <p :if={not @projects?} class="mt-1 text-sm text-base-content/60">
          Start by <.link
            navigate={~p"/projects/new"}
            class="font-medium text-primary hover:underline"
          >adding a project</.link>.
        </p>
      </div>

      <div
        :if={@rows != []}
        class="mt-6 overflow-x-auto rounded-xl border border-base-300 bg-base-100 shadow-sm"
      >
        <table id="issues" class="w-full min-w-[72rem] text-left text-sm">
          <thead class="border-b border-base-300 text-xs uppercase tracking-wide text-base-content/50">
            <tr>
              <th class="px-4 py-3 font-medium">Issue</th>
              <th class="px-4 py-3 font-medium">Stage</th>
              <th :for={{label, _} <- @phases} class="px-4 py-3 font-medium">{label}</th>
              <th class="px-4 py-3 font-medium">Factory time</th>
              <th class="px-4 py-3 font-medium">Waiting on people</th>
              <th class="px-4 py-3 text-right font-medium">Cost</th>
            </tr>
          </thead>
          <tbody class="divide-y divide-base-300">
            <tr
              :for={%{issue: issue} = row <- @rows}
              id={"issue-#{issue.id}"}
              phx-click={JS.navigate(~p"/issues/#{issue.id}")}
              class="cursor-pointer align-top transition hover:bg-base-200/60"
            >
              <td class="max-w-xs px-4 py-3">
                <div class="flex items-center gap-2">
                  <.link
                    navigate={~p"/issues/#{issue.id}"}
                    class="truncate font-medium hover:underline"
                  >
                    {issue.title}
                  </.link>
                  <.difficulty difficulty={issue.difficulty} />
                </div>
                <div class="mt-0.5 text-xs text-base-content/50">
                  {issue.project.repo} #{issue.number}
                </div>
              </td>
              <td class="px-4 py-3">
                <.state_badge state={issue.state} />
                <div class="mt-1 text-xs tabular-nums text-base-content/50">
                  {if Issue.terminal?(issue),
                    do: Format.time(issue.state_entered_at),
                    else: "for " <> Format.duration(Format.seconds(issue.state_entered_at, nil, @now))}
                </div>
              </td>
              <td :for={{_, stage} <- @phases} class="px-4 py-3">
                <% run = last_run(row.runs, stage) %>
                <div class={["tabular-nums", issue.state == stage && "font-medium text-info"]}>
                  {Format.duration(Pipeline.time_in(row.transitions, [stage], @now))}
                </div>
                <.model_tag :if={run} model={run.model} effort={run.effort} />
              </td>
              <td id={"issue-#{issue.id}-factory-time"} class="px-4 py-3 font-medium tabular-nums">
                {Format.duration(Pipeline.time_in(row.transitions, Issue.factory_states(), @now))}
              </td>
              <td
                id={"issue-#{issue.id}-waiting-time"}
                class="px-4 py-3 tabular-nums text-base-content/60"
              >
                {Format.duration(Pipeline.time_in(row.transitions, Issue.waiting_states(), @now))}
              </td>
              <td class="px-4 py-3 text-right tabular-nums">{Format.cost(issue.cost_usd)}</td>
            </tr>
          </tbody>
        </table>
      </div>
    </Layouts.app>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :tone, :string, required: true

  defp tile(assigns) do
    ~H"""
    <div id={@id} class="rounded-xl border border-base-300 bg-base-100 px-4 py-3 shadow-sm">
      <dt class="text-xs text-base-content/60">{@label}</dt>
      <dd class={["mt-1 text-2xl font-semibold tabular-nums", @tone]}>{@value}</dd>
    </div>
    """
  end
end
