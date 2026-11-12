defmodule FactoryWeb.PipelineComponents do
  @moduledoc "Small pieces shared by the issue screens."
  use Phoenix.Component
  alias FactoryWeb.Format

  attr :state, :string, required: true

  def state_badge(assigns) do
    assigns = assign(assigns, :tone, Format.tone(assigns.state))

    ~H"""
    <span class={[
      "inline-flex items-center gap-1.5 whitespace-nowrap rounded-full px-2.5 py-1 text-xs font-medium",
      @tone == :working && "bg-info/10 text-info",
      @tone == :person && "bg-warning/15 text-warning",
      @tone == :failed && "bg-error/10 text-error",
      @tone == :done && "bg-success/15 text-success",
      @tone == :idle && "bg-base-300 text-base-content/60"
    ]}>
      <span class={[
        "size-1.5 rounded-full bg-current",
        @tone == :working && "motion-safe:animate-pulse"
      ]} />
      {Format.state(@state)}
    </span>
    """
  end

  attr :model, :string, default: nil
  attr :effort, :string, default: nil

  def model_tag(assigns) do
    ~H"""
    <span :if={@model} class="whitespace-nowrap text-xs text-base-content/60">
      {Format.model(@model)}<span :if={@effort} class="text-base-content/40"> · {@effort}</span>
    </span>
    """
  end

  attr :difficulty, :string, default: nil

  def difficulty(assigns) do
    ~H"""
    <span
      :if={@difficulty}
      class={[
        "rounded px-1.5 py-0.5 text-[11px] font-semibold uppercase tracking-wide",
        @difficulty == "easy" && "bg-success/15 text-success",
        @difficulty == "medium" && "bg-info/10 text-info",
        @difficulty == "hard" && "bg-error/10 text-error"
      ]}
    >
      {@difficulty}
    </span>
    """
  end
end
