defmodule FactoryWeb.Track do
  @moduledoc """
  An issue's path through the factory as five steps (plan, plan review, develop,
  PR review, merge), each with a status, the time spent and the last agent run.
  """
  alias Factory.Pipeline
  alias Factory.Pipeline.Issue
  alias FactoryWeb.Format

  @steps [
    {"planning", "Plan"},
    {"plan_review", "Plan review"},
    {"developing", "Develop"},
    {"pr_review", "PR review"},
    {"merge", "Merge"}
  ]

  # Where on the line each state sits. Waiting states sit on the step they block.
  @position %{
    "planning" => 0,
    "awaiting_answers" => 0,
    "plan_review" => 1,
    "awaiting_plan_approval" => 1,
    "developing" => 2,
    "pr_review" => 3,
    "ready_to_merge" => 4
  }

  @type step :: %{
          key: String.t(),
          label: String.t(),
          status: :done | :active | :waiting | :failed | :stopped | :pending,
          seconds: non_neg_integer() | nil,
          run: struct() | nil
        }

  @spec steps(Issue.t(), [struct()], [struct()], DateTime.t()) :: [step]
  def steps(%Issue{} = issue, transitions, runs, now) do
    {position, tone} = position(issue, transitions)

    for {{key, label}, index} <- Enum.with_index(@steps) do
      states = if key == "merge", do: ["ready_to_merge"], else: [key]

      %{
        key: key,
        label: label,
        status: status(index, position, tone),
        seconds: Pipeline.time_in(transitions, states, now),
        run: runs |> Enum.filter(&(&1.stage == key)) |> List.last()
      }
    end
  end

  defp position(%Issue{state: "done"}, _transitions), do: {length(@steps), :done}

  defp position(%Issue{state: "cancelled"}, transitions),
    do: {furthest(transitions) + 1, :stopped}

  defp position(%Issue{state: state} = issue, transitions) when state in ~w(needs_human failed) do
    tone = if state == "failed", do: :failed, else: :waiting
    {Map.get(@position, issue.resume_state) || max(furthest(transitions), 0), tone}
  end

  defp position(%Issue{state: state}, _transitions) do
    tone = if Format.tone(state) == :person, do: :waiting, else: :active
    {Map.get(@position, state, -1), tone}
  end

  defp furthest(transitions) do
    transitions |> Enum.map(&Map.get(@position, &1.state, -1)) |> Enum.max(fn -> -1 end)
  end

  defp status(index, position, :stopped) when index < position, do: :stopped
  defp status(index, position, _tone) when index < position, do: :done
  defp status(index, index, tone) when tone in [:active, :waiting, :failed], do: tone
  defp status(_index, _position, _tone), do: :pending
end
