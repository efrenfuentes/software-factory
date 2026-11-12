defmodule Factory.Pipeline.StageRun do
  @moduledoc "One execution of an agent (or of the gates) for an issue."
  use Ecto.Schema

  schema "stage_runs" do
    field :stage, :string
    field :role, :string
    field :round, :integer, default: 0
    field :model, :string
    field :effort, :string
    field :status, :string, default: "running"
    field :started_at, :utc_datetime_usec
    field :finished_at, :utc_datetime_usec
    field :input_tokens, :integer
    field :output_tokens, :integer
    field :cost_usd, :decimal
    field :summary, :string
    field :output, :map

    belongs_to :issue, Factory.Pipeline.Issue
  end
end
