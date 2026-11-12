defmodule FactoryWeb.IssueLive do
  @moduledoc "One issue: its state history with the time spent in each state, and every agent run."
  use FactoryWeb, :live_view
  alias Factory.Pipeline
  alias Factory.Pipeline.{Issue, Poller}
  alias FactoryWeb.Format

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    if connected?(socket) do
      Pipeline.subscribe()
      :timer.send_interval(1000, :tick)
    end

    {:ok, socket |> assign(now: DateTime.utc_now()) |> load(String.to_integer(id))}
  end

  defp load(socket, id) do
    issue = Pipeline.get_issue!(id)
    runs = Pipeline.list_runs(issue)

    assign(socket,
      page_title: "##{issue.number} #{issue.title}",
      issue: issue,
      transitions: Pipeline.list_transitions(issue),
      runs: runs,
      cost:
        runs
        |> Enum.map(& &1.cost_usd)
        |> Enum.reject(&is_nil/1)
        |> Enum.reduce(Decimal.new(0), &Decimal.add/2)
    )
  end

  @impl true
  def handle_info(:tick, socket), do: {:noreply, assign(socket, :now, DateTime.utc_now())}

  def handle_info({:issue_updated, id}, socket) do
    {:noreply, if(id == socket.assigns.issue.id, do: load(socket, id), else: socket)}
  end

  @impl true
  def handle_event("approve", _params, socket) do
    case Pipeline.approve(socket.assigns.issue) do
      {:ok, issue} ->
        {:noreply,
         socket
         |> put_flash(:info, "Continuing with #{Format.state(issue.state)}.")
         |> load(issue.id)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "This issue is not waiting for approval.")}
    end
  end

  def handle_event("stop", _params, socket) do
    {:ok, issue} = Poller.stop(socket.assigns.issue)
    {:noreply, socket |> put_flash(:info, "Stopped.") |> load(issue.id)}
  end

  defp approve_label(%Issue{state: "awaiting_plan_approval"}), do: "Approve plan"
  defp approve_label(%Issue{state: "failed"}), do: "Retry"

  defp approve_label(%Issue{hold_reason: reason})
       when reason in ~w(plan_rounds_exhausted pr_rounds_exhausted), do: "Allow one more round"

  defp approve_label(%Issue{state: "needs_human"}), do: "Try again"
  defp approve_label(_), do: nil

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <.link
        navigate={~p"/"}
        class="inline-flex items-center gap-1 text-sm text-base-content/60 hover:text-base-content"
      >
        <.icon name="hero-arrow-left-micro" class="size-4" /> Issues
      </.link>

      <div class="mt-3 flex flex-wrap items-start justify-between gap-4">
        <div class="min-w-0">
          <div class="flex flex-wrap items-center gap-2 text-sm text-base-content/60">
            <a href={@issue.url} target="_blank" class="hover:underline">
              {@issue.project.repo} #{@issue.number}
            </a>
            <.difficulty difficulty={@issue.difficulty} />
          </div>
          <h1 class="mt-1 text-2xl font-semibold tracking-tight">{@issue.title}</h1>
          <div class="mt-3 flex flex-wrap items-center gap-3 text-sm">
            <.state_badge state={@issue.state} />
            <span :if={not Issue.terminal?(@issue)} class="tabular-nums text-base-content/60">
              for {Format.duration(Format.seconds(@issue.state_entered_at, nil, @now))}
            </span>
            <a
              :if={@issue.pr_url}
              id="pr-link"
              href={@issue.pr_url}
              target="_blank"
              class="inline-flex items-center gap-1 text-primary hover:underline"
            >
              <.icon name="hero-arrow-top-right-on-square-micro" class="size-4" />
              Pull request #{@issue.pr_number}
            </a>
          </div>
        </div>
        <div class="flex gap-2">
          <.button
            :if={approve_label(@issue)}
            id="approve-button"
            variant="primary"
            phx-click="approve"
          >
            {approve_label(@issue)}
          </.button>
          <.button
            :if={not Issue.terminal?(@issue)}
            id="stop-button"
            phx-click="stop"
            data-confirm="Stop working on this issue? Its branch and pull request are kept."
          >
            Stop
          </.button>
        </div>
      </div>

      <div
        :if={@issue.state in ["needs_human", "failed"]}
        id="hold-notice"
        class={[
          "mt-6 rounded-xl border px-4 py-3 text-sm",
          if(@issue.state == "failed",
            do: "border-error/30 bg-error/5",
            else: "border-warning/40 bg-warning/5"
          )
        ]}
      >
        <p class="font-medium">{Format.hold(@issue.hold_reason)}</p>
        <pre
          :if={@issue.hold_detail}
          class="mt-2 max-h-64 overflow-auto whitespace-pre-wrap font-mono text-xs text-base-content/70"
        >{@issue.hold_detail}</pre>
      </div>

      <dl class="mt-6 grid grid-cols-2 gap-3 sm:grid-cols-3 lg:grid-cols-5">
        <.fact
          label="Plan review rounds"
          value={"#{@issue.plan_round} of #{@issue.plan_round_limit}"}
        />
        <.fact label="PR review rounds" value={"#{@issue.pr_round} of #{@issue.pr_round_limit}"} />
        <.fact
          id="factory-time"
          label="Factory time"
          value={Format.duration(Pipeline.time_in(@transitions, Issue.factory_states(), @now))}
        />
        <.fact
          id="waiting-time"
          label="Waiting on people"
          value={Format.duration(Pipeline.time_in(@transitions, Issue.waiting_states(), @now))}
        />
        <.fact label="Cost" value={Format.cost(@cost)} />
      </dl>

      <div class="mt-8 grid gap-8 lg:grid-cols-5">
        <section class="lg:col-span-2">
          <h2 class="text-sm font-semibold uppercase tracking-wide text-base-content/50">Stages</h2>
          <ol id="transitions" class="mt-3 space-y-1">
            <li
              :for={t <- Enum.reverse(@transitions)}
              id={"transition-#{t.id}"}
              class="rounded-lg border border-base-300 bg-base-100 px-3 py-2.5"
            >
              <div class="flex items-center justify-between gap-3">
                <.state_badge :if={is_nil(t.left_at)} state={t.state} />
                <span :if={t.left_at} class="text-sm font-medium">{Format.state(t.state)}</span>
                <span class="text-sm tabular-nums text-base-content/70">
                  {if is_nil(t.left_at) and Issue.terminal?(@issue),
                    do: "",
                    else: Format.duration(Format.seconds(t.entered_at, t.left_at, @now))}
                </span>
              </div>
              <p :if={t.note} class="mt-1 line-clamp-2 text-xs text-base-content/60">{t.note}</p>
              <p class="mt-1 text-[11px] text-base-content/40">{Format.time(t.entered_at)}</p>
            </li>
          </ol>
        </section>

        <section class="lg:col-span-3">
          <h2 class="text-sm font-semibold uppercase tracking-wide text-base-content/50">
            Agent runs
          </h2>
          <p :if={@runs == []} class="mt-3 text-sm text-base-content/60">Nothing has run yet.</p>
          <ol id="runs" class="mt-3 space-y-2">
            <li
              :for={run <- Enum.reverse(@runs)}
              id={"run-#{run.id}"}
              class="rounded-lg border border-base-300 bg-base-100 px-4 py-3"
            >
              <div class="flex flex-wrap items-center justify-between gap-x-4 gap-y-1">
                <div class="flex items-center gap-2">
                  <span class={[
                    "size-2 rounded-full",
                    run.status == "running" && "bg-info motion-safe:animate-pulse",
                    run.status == "ok" && "bg-success",
                    run.status == "failed" && "bg-error"
                  ]} />
                  <span class="text-sm font-medium">{Format.state(run.stage)}</span>
                  <span class="text-xs text-base-content/50">
                    {String.capitalize(run.role)}{if run.stage == "gates",
                      do: " · attempt #{run.round}",
                      else: " · round #{run.round}"}
                  </span>
                </div>
                <.model_tag model={run.model} effort={run.effort} />
              </div>
              <div class="mt-1.5 flex flex-wrap gap-x-4 text-xs tabular-nums text-base-content/60">
                <span>{Format.duration(Format.seconds(run.started_at, run.finished_at, @now))}</span>
                <span :if={run.input_tokens}>
                  {Format.tokens(run.input_tokens)} in · {Format.tokens(run.output_tokens)} out
                </span>
                <span :if={run.cost_usd}>{Format.cost(run.cost_usd)}</span>
                <span :if={run.output && run.output["verdict"]} class="font-medium">
                  {String.replace(run.output["verdict"], "_", " ")}
                </span>
              </div>
              <p :if={run.summary} class="mt-2 text-sm text-base-content/80">{run.summary}</p>
              <ul
                :if={run.output && (run.output["blocking"] || []) != []}
                class="mt-2 list-disc space-y-1 pl-5 text-sm text-base-content/80"
              >
                <li :for={item <- run.output["blocking"]}>{item}</li>
              </ul>
            </li>
          </ol>
        </section>
      </div>
    </Layouts.app>
    """
  end

  attr :id, :string, default: nil
  attr :label, :string, required: true
  attr :value, :string, required: true

  defp fact(assigns) do
    ~H"""
    <div id={@id} class="rounded-xl border border-base-300 bg-base-100 px-4 py-3">
      <dt class="text-xs text-base-content/60">{@label}</dt>
      <dd class="mt-1 font-semibold tabular-nums">{@value}</dd>
    </div>
    """
  end
end
