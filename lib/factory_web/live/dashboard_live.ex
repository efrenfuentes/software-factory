defmodule FactoryWeb.DashboardLive do
  @moduledoc "Every issue in the factory: where it is, how long each stage took and which model ran it."
  use FactoryWeb, :live_view
  alias Factory.Pipeline
  alias Factory.Pipeline.Issue
  alias FactoryWeb.{Format, Track}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Pipeline.subscribe()
      :timer.send_interval(1000, :tick)
    end

    {:ok, socket |> assign(page_title: "Issues", now: DateTime.utc_now()) |> load()}
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

  defp row_edge(state) do
    case Format.tone(state) do
      :person -> "border-l-warning"
      :failed -> "border-l-error"
      :working -> "border-l-primary"
      _ -> "border-l-base-300"
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active={:issues}>
      <h1 class="text-2xl font-semibold tracking-tight">Issues</h1>
      <p class="mt-1 max-w-prose text-sm text-base-content/60">
        GitHub is checked every minute for labelled issues, answers and merged pull requests.
      </p>

      <.figures class="mt-5 grid-cols-2 lg:grid-cols-4">
        <.figure
          id="stat-working"
          label="Being worked on"
          value={to_string(@working)}
          tone="text-primary"
        />
        <.figure
          id="stat-waiting"
          label="Waiting on you"
          value={to_string(@waiting)}
          tone="text-warning"
        />
        <.figure id="stat-done" label="Merged" value={to_string(@done)} tone="text-success" />
        <.figure id="stat-cost" label="Total cost" value={Format.cost(@cost)} />
      </.figures>

      <div
        :if={@rows == []}
        id="empty-state"
        class="mt-6 rounded-lg border border-dashed border-base-300 bg-base-100 px-5 py-14 text-center"
      >
        <.icon name="hero-inbox" class="size-8 text-base-content/30" />
        <p class="mt-3 font-medium">No issues yet</p>
        <p :if={@projects?} class="mx-auto mt-1 max-w-sm text-sm text-base-content/60">
          Add a project's trigger label to a GitHub issue and it shows up here within a minute.
        </p>
        <p :if={not @projects?} class="mx-auto mt-1 max-w-sm text-sm text-base-content/60">
          Start by <.link
            navigate={~p"/projects/new"}
            class="font-medium text-primary underline underline-offset-2"
          >adding a project</.link>.
        </p>
      </div>

      <ul :if={@rows != []} id="issues" class="mt-4 space-y-2">
        <li :for={%{issue: issue} = row <- @rows} id={"issue-#{issue.id}"}>
          <.link
            navigate={~p"/issues/#{issue.id}"}
            class={[
              "group block rounded-lg border border-l-2 border-base-300 bg-base-100 p-4 transition hover:border-base-content/40",
              "lg:grid lg:grid-cols-[minmax(0,1fr)_25rem_10rem_4rem] lg:items-center lg:gap-6",
              row_edge(issue.state)
            ]}
          >
            <div class="min-w-0">
              <div class="truncate font-medium transition group-hover:text-primary">
                {issue.title}
              </div>
              <div class="mt-0.5 truncate font-mono text-xs text-base-content/50">
                {issue.project.repo} #{issue.number}
              </div>
              <div class="mt-2 flex flex-wrap items-center gap-x-2 gap-y-1">
                <.state_badge state={issue.state} />
                <.difficulty difficulty={issue.difficulty} />
                <span class="font-mono text-xs tabular-nums text-base-content/50">
                  {if Issue.terminal?(issue),
                    do: Format.time(issue.state_entered_at),
                    else: "for " <> Format.duration(Format.seconds(issue.state_entered_at, nil, @now))}
                </span>
              </div>
            </div>

            <.stage_track
              steps={Track.steps(issue, row.transitions, row.runs, @now)}
              class="mt-4 lg:mt-0"
            />

            <div class="mt-4 flex items-end gap-5 lg:contents">
              <.time_split
                class="flex-1"
                id_prefix={"issue-#{issue.id}-"}
                factory={Pipeline.time_in(row.transitions, Issue.factory_states(), @now)}
                waiting={Pipeline.time_in(row.transitions, Issue.waiting_states(), @now)}
              />
              <div class="shrink-0 text-right">
                <div class="font-mono text-sm tabular-nums">{Format.cost(issue.cost_usd)}</div>
                <div class="text-[11px] text-base-content/50">cost</div>
              </div>
            </div>
          </.link>
        </li>
      </ul>
    </Layouts.app>
    """
  end
end
