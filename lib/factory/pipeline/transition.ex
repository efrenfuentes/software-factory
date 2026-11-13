defmodule Factory.Pipeline.Transition do
  @moduledoc "A period an issue spent in one state. `left_at` is nil while it is the current one."
  use Ecto.Schema

  schema "transitions" do
    field :state, :string
    field :note, :string
    # Why the issue waited, for `needs_human` periods.
    field :hold_reason, :string
    field :entered_at, :utc_datetime_usec
    field :left_at, :utc_datetime_usec

    belongs_to :issue, Factory.Pipeline.Issue
  end
end
