defmodule Factory.Pipeline.Issue do
  @moduledoc "A GitHub issue being taken through the factory."
  use Ecto.Schema

  @type t :: %__MODULE__{}

  # A job is running for the issue.
  @active ~w(planning plan_review developing pr_review)
  # The factory is waiting for a person (or for the PR to be merged).
  @waiting ~w(awaiting_answers awaiting_plan_approval needs_human ready_to_merge failed)
  @terminal ~w(done cancelled)

  schema "issues" do
    field :number, :integer
    field :title, :string
    field :url, :string
    field :body_hash, :string
    field :state, :string, default: "queued"
    field :state_entered_at, :utc_datetime_usec
    field :difficulty, :string
    field :plan_round, :integer, default: 0
    field :plan_round_limit, :integer
    field :pr_round, :integer, default: 0
    field :pr_round_limit, :integer
    field :branch, :string
    field :pr_number, :integer
    field :pr_url, :string
    field :hold_reason, :string
    field :hold_detail, :string
    field :resume_state, :string
    field :comments_seen_at, :utc_datetime_usec

    field :cost_usd, :decimal, virtual: true

    belongs_to :project, Factory.Projects.Project
    has_many :transitions, Factory.Pipeline.Transition
    has_many :stage_runs, Factory.Pipeline.StageRun

    timestamps(type: :utc_datetime)
  end

  def active_states, do: @active
  def waiting_states, do: @waiting

  @doc "States where time counts as the factory's own: queued for a slot, or an agent working."
  def factory_states, do: ["queued" | @active]
  def terminal_states, do: @terminal
  def states, do: ["queued"] ++ @active ++ @waiting ++ @terminal

  def active?(%__MODULE__{state: state}), do: state in @active
  def waiting?(%__MODULE__{state: state}), do: state in @waiting
  def terminal?(%__MODULE__{state: state}), do: state in @terminal
end
