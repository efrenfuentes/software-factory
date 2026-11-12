defmodule FactoryWeb.PipelineComponents do
  @moduledoc "Pieces shared by the issue screens: the stage line, state badges, time and model tags."
  use Phoenix.Component
  import FactoryWeb.CoreComponents, only: [icon: 1]
  alias FactoryWeb.Format

  attr :state, :string, required: true

  def state_badge(assigns) do
    assigns = assign(assigns, :tone, Format.tone(assigns.state))

    ~H"""
    <span class={[
      "inline-flex items-center gap-1.5 whitespace-nowrap rounded-full border px-2 py-0.5 text-xs font-medium",
      @tone == :working && "border-primary/30 bg-primary/10 text-primary",
      @tone == :person && "border-warning/40 bg-warning/10 text-warning",
      @tone == :failed && "border-error/40 bg-error/10 text-error",
      @tone == :done && "border-success/40 bg-success/10 text-success",
      @tone == :idle && "border-base-300 bg-base-200 text-base-content/60"
    ]}>
      <span class={[
        "size-1.5 rounded-full bg-current",
        @tone == :working && "motion-safe:animate-pulse"
      ]} />
      {Format.state(@state)}
    </span>
    """
  end

  attr :steps, :list, required: true, doc: "from `FactoryWeb.Track.steps/4`"
  attr :id, :string, default: nil
  attr :size, :atom, values: [:compact, :full], default: :compact
  attr :class, :any, default: nil

  @doc """
  The issue's path as a line of five nodes. Under each node: the step, the time
  spent in it and the model that ran it.
  """
  def stage_track(assigns) do
    ~H"""
    <ol id={@id} class={["flex w-full", @class]} aria-label="Stages">
      <li
        :for={{step, index} <- Enum.with_index(@steps)}
        class="relative min-w-0 flex-1 text-center"
        data-status={step.status}
        aria-current={step.status in [:active, :waiting, :failed] && "step"}
      >
        <span
          :if={index > 0}
          aria-hidden="true"
          class={[
            "absolute right-1/2 h-px w-full",
            if(@size == :full, do: "top-3.5", else: "top-2"),
            if(step.status == :pending, do: "bg-base-300", else: "bg-base-content/50")
          ]}
        />
        <span class={[
          "relative z-[1] mx-auto grid place-items-center rounded-full border",
          if(@size == :full, do: "size-7", else: "size-4"),
          step.status == :done && "border-base-content bg-base-content text-base-100",
          step.status == :active && "stage-active border-primary bg-primary text-primary-content",
          step.status == :waiting && "border-warning bg-base-100 text-warning",
          step.status == :failed && "border-error bg-error text-base-100",
          step.status == :stopped && "border-base-300 bg-base-300 text-base-content/60",
          step.status == :pending && "border-base-300 bg-base-100 text-transparent"
        ]}>
          <.icon
            name={node_icon(step.status)}
            class={if(@size == :full, do: "size-4", else: "size-2.5")}
          />
        </span>
        <div class={[
          "mt-1.5 truncate px-0.5 leading-tight",
          if(@size == :full, do: "text-xs sm:text-sm", else: "text-[11px]"),
          if(step.status == :pending, do: "text-base-content/40", else: "font-medium")
        ]}>
          {step.label}
        </div>
        <div class={[
          "font-mono tabular-nums leading-tight text-base-content/60",
          if(@size == :full, do: "mt-0.5 text-xs", else: "text-[11px]"),
          step.status == :active && "text-primary"
        ]}>
          {if step.seconds, do: Format.duration(step.seconds), else: " "}
        </div>
        <div
          :if={step.run}
          class={[
            "truncate px-0.5 leading-tight text-base-content/50",
            if(@size == :full,
              do: "mt-0.5 text-[11px] sm:text-xs",
              else: "hidden text-[11px] sm:block"
            )
          ]}
          title={"#{Format.model(step.run.model)} · #{step.run.effort}"}
        >
          {Format.model(step.run.model)}
          <span :if={@size == :full} class="hidden text-base-content/40 sm:inline">
            {step.run.effort}
          </span>
        </div>
      </li>
    </ol>
    """
  end

  defp node_icon(:done), do: "hero-check-micro"
  defp node_icon(:active), do: "hero-bolt-micro"
  defp node_icon(:waiting), do: "hero-pause-micro"
  defp node_icon(:failed), do: "hero-x-mark-micro"
  defp node_icon(:stopped), do: "hero-minus-micro"
  defp node_icon(:pending), do: "hero-minus-micro"

  attr :factory, :integer, default: nil, doc: "seconds queued or with an agent working"
  attr :waiting, :integer, default: nil, doc: "seconds waiting on a person"
  attr :id_prefix, :string, default: nil
  attr :class, :any, default: nil

  @doc "Factory time against time waiting on people, as two figures over one proportional bar."
  def time_split(assigns) do
    factory = assigns.factory || 0
    waiting = assigns.waiting || 0
    total = max(factory + waiting, 1)
    assigns = assign(assigns, share: round(factory * 100 / total), empty?: factory + waiting == 0)

    ~H"""
    <div class={["min-w-0", @class]}>
      <div class="flex items-baseline justify-between gap-3 font-mono text-xs tabular-nums">
        <span id={@id_prefix && "#{@id_prefix}factory-time"} title="Factory time" class="text-primary">
          {Format.duration(@factory)}
        </span>
        <span
          id={@id_prefix && "#{@id_prefix}waiting-time"}
          title="Waiting on people"
          class="text-warning"
        >
          {Format.duration(@waiting)}
        </span>
      </div>
      <div class="mt-1 flex h-1.5 gap-px overflow-hidden rounded-full bg-base-300" aria-hidden="true">
        <span :if={not @empty?} class="bg-primary" style={"width: #{@share}%"} />
        <span :if={not @empty?} class="flex-1 bg-warning" />
      </div>
      <div class="mt-1 flex justify-between gap-3 text-[11px] text-base-content/50">
        <span>factory</span>
        <span>waiting on people</span>
      </div>
    </div>
    """
  end

  attr :text, :string, required: true
  attr :id, :string, default: nil
  attr :class, :any, default: nil
  attr :breaks, :boolean, default: true, doc: "keep single line breaks"

  @doc "Text written by an agent, rendered from Markdown."
  def markdown(assigns) do
    ~H"""
    <div id={@id} class={["markdown", @class]}>
      {FactoryWeb.Markdown.to_html(@text, breaks: @breaks)}
    </div>
    """
  end

  attr :model, :string, default: nil
  attr :effort, :string, default: nil

  def model_tag(assigns) do
    ~H"""
    <span :if={@model} class="whitespace-nowrap font-mono text-xs text-base-content/70">
      {Format.model(@model)}<span :if={@effort} class="text-base-content/40"> {@effort}</span>
    </span>
    """
  end

  attr :difficulty, :string, default: nil

  def difficulty(assigns) do
    ~H"""
    <span
      :if={@difficulty}
      title="Difficulty set by the Planner"
      class={[
        "inline-flex items-center gap-1 whitespace-nowrap rounded border px-1.5 py-px font-mono text-[11px]",
        @difficulty == "easy" && "border-success/40 text-success",
        @difficulty == "medium" && "border-primary/40 text-primary",
        @difficulty == "hard" && "border-error/40 text-error"
      ]}
    >
      {@difficulty}
    </span>
    """
  end

  attr :role, :string, required: true

  @doc "What a user may do, in one word."
  def role_badge(assigns) do
    ~H"""
    <span class={[
      "inline-flex items-center whitespace-nowrap rounded border px-1.5 py-px font-mono text-[11px]",
      @role == "admin" && "border-primary/40 text-primary",
      @role == "operator" && "border-success/40 text-success",
      @role == "viewer" && "border-base-300 text-base-content/60"
    ]}>
      {Format.role(@role)}
    </span>
    """
  end

  attr :id, :string, default: nil
  attr :class, :any, default: nil
  slot :inner_block, required: true

  @doc "A group of figures in one bordered panel, separated by hairlines."
  def figures(assigns) do
    ~H"""
    <dl
      id={@id}
      class={[
        "grid gap-px overflow-hidden rounded-lg border border-base-300 bg-base-300",
        @class
      ]}
    >
      {render_slot(@inner_block)}
    </dl>
    """
  end

  attr :id, :string, default: nil
  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :tone, :any, default: nil
  attr :class, :any, default: nil

  def figure(assigns) do
    ~H"""
    <div id={@id} class={["bg-base-100 px-4 py-3", @class]}>
      <dt class="text-xs text-base-content/60">{@label}</dt>
      <dd class={["mt-1 font-mono text-xl font-medium tabular-nums sm:text-2xl", @tone]}>
        {@value}
      </dd>
    </div>
    """
  end
end
