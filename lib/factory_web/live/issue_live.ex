defmodule FactoryWeb.IssueLive do
  @moduledoc "One issue: its state history with the time spent in each state, and every agent run."
  use FactoryWeb, :live_view
  alias Factory.Pipeline
  alias Factory.Pipeline.{Issue, Poller}
  alias Factory.Workspace
  alias FactoryWeb.{Format, Track}

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    if connected?(socket) do
      Pipeline.subscribe()
      :timer.send_interval(1000, :tick)
    end

    {:ok,
     socket
     |> assign(now: DateTime.utc_now(), plan_tab: nil, plan_choice: nil)
     |> assign(feedback: feedback_form(""))
     |> load(String.to_integer(id))}
  end

  defp load(socket, id) do
    issue = Pipeline.get_issue!(id)
    runs = Pipeline.list_runs(issue)

    plan = Workspace.impl().read_plan(issue.project, issue)

    assign(socket,
      page_title: "##{issue.number} #{issue.title}",
      issue: issue,
      plan: plan,
      # Open while the plan waits for a decision, unless the person chose otherwise.
      plan_open:
        if(is_nil(socket.assigns.plan_choice),
          do: issue.state == "awaiting_plan_approval",
          else: socket.assigns.plan_choice
        ),
      plan_file: Enum.find(plan, &(&1.name == socket.assigns.plan_tab)) || List.first(plan),
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

  def handle_event("plan_tab", %{"file" => name}, socket) do
    {:noreply,
     assign(socket,
       plan_tab: name,
       plan_file: Enum.find(socket.assigns.plan, &(&1.name == name))
     )}
  end

  def handle_event("toggle_plan", _params, socket) do
    open? = not socket.assigns.plan_open
    {:noreply, assign(socket, plan_choice: open?, plan_open: open?)}
  end

  def handle_event("feedback_changed", %{"review" => %{"feedback" => text}}, socket) do
    {:noreply, assign(socket, feedback: feedback_form(text))}
  end

  def handle_event("request_changes", %{"review" => %{"feedback" => text}}, socket) do
    text = String.trim(text)

    cond do
      text == "" ->
        {:noreply, put_flash(socket, :error, "Write what should change in the plan.")}

      true ->
        case Poller.request_plan_changes(socket.assigns.issue, text) do
          {:ok, issue} ->
            {:noreply,
             socket
             |> assign(feedback: feedback_form(""))
             |> put_flash(:info, "Feedback posted on the issue. The plan is being revised.")
             |> load(issue.id)}

          {:error, :not_waiting_for_approval} ->
            {:noreply, put_flash(socket, :error, "This issue is not waiting for approval.")}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Could not post on GitHub: #{inspect(reason)}")}
        end
    end
  end

  def handle_event("stop", _params, socket) do
    {:ok, issue} = Poller.stop(socket.assigns.issue)
    {:noreply, socket |> put_flash(:info, "Stopped.") |> load(issue.id)}
  end

  defp feedback_form(text), do: to_form(%{"feedback" => text}, as: :review)

  defp plan_label("spec.md"), do: "Spec"
  defp plan_label("plan.md"), do: "Plan"
  defp plan_label("tasks.md"), do: "Tasks"
  defp plan_label(name), do: name

  defp approve_label(%Issue{state: "awaiting_plan_approval"}), do: "Approve plan"
  defp approve_label(%Issue{state: "failed"}), do: "Retry"

  defp approve_label(%Issue{hold_reason: reason})
       when reason in ~w(plan_rounds_exhausted pr_rounds_exhausted), do: "Allow one more round"

  defp approve_label(%Issue{state: "needs_human"}), do: "Try again"
  defp approve_label(_), do: nil

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} active={:issues}>
      <.link
        navigate={~p"/"}
        class="inline-flex min-h-8 items-center gap-1 rounded text-sm text-base-content/60 transition hover:text-base-content"
      >
        <.icon name="hero-arrow-left-micro" class="size-4" /> Issues
      </.link>

      <div class="mt-2 flex flex-col gap-4 sm:flex-row sm:items-start sm:justify-between">
        <div class="min-w-0">
          <a
            href={@issue.url}
            target="_blank"
            class="font-mono text-xs text-base-content/60 underline-offset-2 hover:underline"
          >
            {@issue.project.repo} #{@issue.number}
          </a>
          <h1 class="mt-1 text-xl font-semibold tracking-tight [overflow-wrap:anywhere] sm:text-2xl">
            {@issue.title}
          </h1>
          <div class="mt-3 flex flex-wrap items-center gap-x-3 gap-y-2 text-sm">
            <.state_badge state={@issue.state} />
            <.difficulty difficulty={@issue.difficulty} />
            <span
              :if={not Issue.terminal?(@issue)}
              class="font-mono text-xs tabular-nums text-base-content/60"
            >
              for {Format.duration(Format.seconds(@issue.state_entered_at, nil, @now))}
            </span>
            <a
              :if={@issue.pr_url}
              id="pr-link"
              href={@issue.pr_url}
              target="_blank"
              class="inline-flex items-center gap-1 text-primary underline-offset-2 hover:underline"
            >
              <.icon name="hero-arrow-top-right-on-square-micro" class="size-4" />
              Pull request #{@issue.pr_number}
            </a>
          </div>
        </div>
        <div class="flex shrink-0 gap-2">
          <.button
            :if={approve_label(@issue)}
            id="approve-button"
            variant="primary"
            phx-click="approve"
            class="flex-1 sm:flex-none"
          >
            {approve_label(@issue)}
          </.button>
          <.button
            :if={not Issue.terminal?(@issue)}
            id="stop-button"
            phx-click="stop"
            data-confirm="Stop working on this issue? Its branch and pull request are kept."
            class="flex-1 sm:flex-none"
          >
            Stop
          </.button>
        </div>
      </div>

      <div class="mt-5 rounded-lg border border-base-300 bg-base-100 px-2 py-5 sm:px-6">
        <.stage_track
          id="stage-track"
          size={:full}
          steps={Track.steps(@issue, @transitions, @runs, @now)}
        />
      </div>

      <div
        :if={@issue.state in ["needs_human", "failed"]}
        id="hold-notice"
        class={[
          "mt-3 rounded-lg border border-l-2 bg-base-100 px-4 py-3 text-sm",
          if(@issue.state == "failed",
            do: "border-error/40 border-l-error",
            else: "border-warning/40 border-l-warning"
          )
        ]}
      >
        <p class="font-medium">{Format.hold(@issue.hold_reason)}</p>
        <pre
          :if={@issue.hold_detail}
          class="mt-2 max-h-64 overflow-auto whitespace-pre-wrap font-mono text-xs text-base-content/70 [overflow-wrap:anywhere]"
        >{@issue.hold_detail}</pre>
      </div>

      <div class="mt-3 grid gap-3 lg:grid-cols-[minmax(0,1fr)_20rem]">
        <.figures class="grid-cols-3">
          <.figure
            label="Plan rounds"
            value={"#{@issue.plan_round}/#{@issue.plan_round_limit}"}
          />
          <.figure label="PR rounds" value={"#{@issue.pr_round}/#{@issue.pr_round_limit}"} />
          <.figure label="Cost" value={Format.cost(@cost)} />
        </.figures>
        <div class="rounded-lg border border-base-300 bg-base-100 px-4 py-3">
          <.time_split
            id_prefix=""
            factory={Pipeline.time_in(@transitions, Issue.factory_states(), @now)}
            waiting={Pipeline.time_in(@transitions, Issue.waiting_states(), @now)}
          />
        </div>
      </div>

      <section
        :if={@plan != []}
        id="plan"
        class={[
          "mt-3 rounded-lg border bg-base-100",
          if(@issue.state == "awaiting_plan_approval",
            do: "border-warning/60",
            else: "border-base-300"
          )
        ]}
      >
        <div class="flex flex-wrap items-center justify-between gap-x-3 gap-y-2 px-3 py-2 sm:px-4">
          <button
            id="plan-toggle"
            type="button"
            phx-click="toggle_plan"
            aria-expanded={to_string(@plan_open)}
            class="flex min-h-10 cursor-pointer items-center gap-2 rounded text-left font-semibold transition hover:text-primary"
          >
            <span class={["flex transition-transform", @plan_open && "rotate-90"]}>
              <.icon name="hero-chevron-right-micro" class="size-4" />
            </span>
            Plan
            <span
              :if={@issue.state == "awaiting_plan_approval"}
              class="text-sm font-normal text-warning"
            >
              waiting for your decision
            </span>
          </button>
          <div
            :if={@plan_open}
            id="plan-tabs"
            role="tablist"
            class="flex rounded-md border border-base-300 p-0.5"
          >
            <button
              :for={file <- @plan}
              id={"plan-tab-#{Path.rootname(file.name)}"}
              type="button"
              role="tab"
              aria-selected={to_string(file.name == @plan_file.name)}
              phx-click="plan_tab"
              phx-value-file={file.name}
              class={[
                "min-h-8 cursor-pointer rounded px-3 text-sm transition",
                if(file.name == @plan_file.name,
                  do: "bg-base-200 font-medium text-base-content",
                  else: "text-base-content/60 hover:text-base-content"
                )
              ]}
            >
              {plan_label(file.name)}
            </button>
          </div>
        </div>

        <div :if={@plan_open} class="border-t border-base-300">
          <.markdown
            id="plan-content"
            text={@plan_file.content}
            breaks={false}
            class="max-h-[70vh] overflow-auto px-4 py-4 text-sm leading-relaxed sm:px-6"
          />

          <.form
            :if={@issue.state == "awaiting_plan_approval"}
            for={@feedback}
            id="plan-feedback-form"
            phx-change="feedback_changed"
            phx-submit="request_changes"
            class="border-t border-base-300 px-4 py-4 sm:px-6"
          >
            <.input
              field={@feedback[:feedback]}
              type="textarea"
              label="Ask for changes"
              placeholder="What should change in the plan?"
              rows="3"
            />
            <p class="-mt-1 text-xs text-base-content/60">
              Posted on the GitHub issue as your comment; the Planner then revises the plan.
            </p>
            <div class="mt-3 flex flex-col-reverse gap-2 sm:flex-row sm:justify-end">
              <.button id="request-changes-button" type="submit" phx-disable-with="Posting…">
                Request changes
              </.button>
              <.button id="approve-plan-button" type="button" variant="primary" phx-click="approve">
                Approve plan
              </.button>
            </div>
          </.form>
        </div>
      </section>

      <div class="mt-8 grid gap-8 lg:grid-cols-[18rem_minmax(0,1fr)]">
        <section>
          <h2 class="text-sm font-semibold">History</h2>
          <ol id="transitions" class="mt-3">
            <li
              :for={t <- Enum.reverse(@transitions)}
              id={"transition-#{t.id}"}
              class="relative pb-4 pl-6 last:pb-0"
            >
              <span
                aria-hidden="true"
                class="absolute bottom-0 left-[5px] top-2 w-px bg-base-300 [li:last-child>&]:hidden"
              />
              <span
                aria-hidden="true"
                class={[
                  "absolute left-0 top-1.5 size-[11px] rounded-full border-2",
                  if(is_nil(t.left_at),
                    do: tone_dot(@issue.state),
                    else: "border-base-content/40 bg-base-100"
                  )
                ]}
              />
              <div class="flex items-baseline justify-between gap-3">
                <span class={["text-sm", is_nil(t.left_at) && "font-semibold"]}>
                  {Format.state(t.state)}
                </span>
                <span class="font-mono text-xs tabular-nums text-base-content/60">
                  {if is_nil(t.left_at) and Issue.terminal?(@issue),
                    do: "",
                    else: Format.duration(Format.seconds(t.entered_at, t.left_at, @now))}
                </span>
              </div>
              <p
                :if={t.note}
                class="mt-0.5 line-clamp-2 text-xs text-base-content/60 [overflow-wrap:anywhere]"
              >
                {t.note}
              </p>
              <p class="mt-0.5 font-mono text-[11px] text-base-content/40">
                {Format.time(t.entered_at)}
              </p>
            </li>
          </ol>
        </section>

        <section class="min-w-0">
          <h2 class="text-sm font-semibold">Agent runs</h2>
          <p :if={@runs == []} class="mt-3 text-sm text-base-content/60">Nothing has run yet.</p>
          <ol id="runs" class="mt-3 space-y-2">
            <li
              :for={run <- Enum.reverse(@runs)}
              id={"run-#{run.id}"}
              class="rounded-lg border border-base-300 bg-base-100 px-4 py-3"
            >
              <div class="flex flex-wrap items-center justify-between gap-x-4 gap-y-1">
                <div class="flex min-w-0 items-center gap-2">
                  <span class={[
                    "size-2 shrink-0 rounded-full",
                    run.status == "running" && "bg-primary motion-safe:animate-pulse",
                    run.status == "ok" && "bg-success",
                    run.status == "failed" && "bg-error"
                  ]} />
                  <span class="text-sm font-medium">{Format.state(run.stage)}</span>
                  <span class="truncate text-xs text-base-content/50">
                    {String.capitalize(run.role)}, {if run.stage == "gates",
                      do: "attempt #{run.round}",
                      else: "round #{run.round}"}
                  </span>
                </div>
                <.model_tag model={run.model} effort={run.effort} />
              </div>
              <div class="mt-1.5 flex flex-wrap gap-x-4 gap-y-0.5 font-mono text-xs tabular-nums text-base-content/60">
                <span>{Format.duration(Format.seconds(run.started_at, run.finished_at, @now))}</span>
                <span :if={run.input_tokens}>
                  {Format.tokens(run.input_tokens)} in / {Format.tokens(run.output_tokens)} out
                </span>
                <span :if={run.cost_usd}>{Format.cost(run.cost_usd)}</span>
                <span
                  :if={run.output && run.output["verdict"]}
                  class={[
                    "font-sans font-medium",
                    if(run.output["verdict"] == "approve", do: "text-success", else: "text-warning")
                  ]}
                >
                  {String.replace(run.output["verdict"], "_", " ")}
                </span>
              </div>
              <.markdown
                :if={run.summary}
                text={run.summary}
                class="run-summary mt-2 text-sm leading-relaxed text-base-content/80 [overflow-wrap:anywhere]"
              />
              <ul
                :if={run.output && (run.output["blocking"] || []) != []}
                class="mt-2 list-disc space-y-1 pl-5 text-sm text-base-content/80 [overflow-wrap:anywhere]"
              >
                <li :for={item <- run.output["blocking"]}><.markdown text={item} /></li>
              </ul>
            </li>
          </ol>
        </section>
      </div>
    </Layouts.app>
    """
  end

  defp tone_dot(state) do
    case Format.tone(state) do
      :working -> "border-primary bg-primary"
      :person -> "border-warning bg-warning"
      :failed -> "border-error bg-error"
      :done -> "border-success bg-success"
      _ -> "border-base-content/40 bg-base-content/40"
    end
  end
end
