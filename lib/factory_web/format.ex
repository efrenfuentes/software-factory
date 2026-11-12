defmodule FactoryWeb.Format do
  @moduledoc "How durations, models, costs and states are shown."

  @state_labels %{
    "queued" => "Queued",
    "planning" => "Planning",
    "awaiting_answers" => "Awaiting answers",
    "plan_review" => "Plan review",
    "awaiting_plan_approval" => "Awaiting plan approval",
    "developing" => "Developing",
    "pr_review" => "PR review",
    "needs_human" => "Needs a person",
    "ready_to_merge" => "Ready to merge",
    "failed" => "Failed",
    "done" => "Done",
    "cancelled" => "Cancelled",
    "gates" => "Checks"
  }

  @hold_labels %{
    "plan_rounds_exhausted" => "The plan was not approved within the review rounds allowed",
    "pr_rounds_exhausted" => "The pull request was not approved within the review rounds allowed",
    "gates_failed" => "Tests or lint keep failing",
    "no_changes" => "The Developer changed no code",
    "developer_blocked" => "The Developer is blocked",
    "error" => "A stage failed to run"
  }

  def state(state), do: Map.get(@state_labels, state, state)
  def hold(reason), do: Map.get(@hold_labels, reason, reason)

  @doc "Who or what the issue is waiting on, which decides its color."
  def tone(state) when state in ~w(queued planning plan_review developing pr_review), do: :working

  def tone(state)
      when state in ~w(awaiting_answers awaiting_plan_approval needs_human ready_to_merge),
      do: :person

  def tone("failed"), do: :failed
  def tone("done"), do: :done
  def tone(_), do: :idle

  def duration(nil), do: "—"
  def duration(seconds) when seconds < 60, do: "#{seconds}s"
  def duration(seconds) when seconds < 3600, do: "#{div(seconds, 60)}m #{rem(seconds, 60)}s"

  def duration(seconds) when seconds < 86_400,
    do: "#{div(seconds, 3600)}h #{div(rem(seconds, 3600), 60)}m"

  def duration(seconds), do: "#{div(seconds, 86_400)}d #{div(rem(seconds, 86_400), 3600)}h"

  @doc "Seconds between two instants; an open period runs until `now`."
  def seconds(from, to, now), do: max(DateTime.diff(to || now, from, :second), 0)

  def role("admin"), do: "administrator"
  def role("operator"), do: "operator"
  def role("viewer"), do: "read only"
  def role(other), do: other

  def model(nil), do: nil

  def model("claude-" <> rest) do
    case String.split(rest, "-") do
      [family | version] -> String.capitalize(family) <> " " <> Enum.join(version, ".")
    end
  end

  def model("gpt-" <> rest) do
    case String.split(rest, "-") do
      [version | name] -> Enum.join(["GPT", version | Enum.map(name, &String.capitalize/1)], " ")
    end
  end

  def model(other), do: other

  def cost(nil), do: "—"
  def cost(%Decimal{} = amount), do: "$" <> (amount |> Decimal.round(2) |> Decimal.to_string())

  def tokens(nil), do: "—"
  def tokens(n) when n >= 1_000_000, do: "#{Float.round(n / 1_000_000, 1)}M"
  def tokens(n) when n >= 1_000, do: "#{Float.round(n / 1_000, 1)}k"
  def tokens(n), do: to_string(n)

  def time(%DateTime{} = at), do: Calendar.strftime(at, "%b %d, %H:%M:%S UTC")
end
