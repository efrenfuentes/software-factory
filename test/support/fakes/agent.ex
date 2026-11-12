defmodule Factory.Fakes.Agent do
  @moduledoc "Answers each role from a script set with `script/2`."
  @behaviour Factory.Agents
  alias Factory.Fakes.State

  @defaults %{
    planner: %{
      "status" => "ready",
      "summary" => "Plan",
      "questions" => [],
      "difficulty" => "easy",
      "difficulty_reason" => "small"
    },
    reviewer: %{
      "verdict" => "approve",
      "summary" => "Looks good",
      "blocking" => [],
      "minor" => []
    },
    developer: %{"status" => "done", "summary" => "Implemented"}
  }

  def script(role, answers), do: State.update(:scripts, &Map.put(&1, role, answers))
  def requests, do: State.get(:requests) |> Enum.reverse()

  @impl true
  def run(request) do
    State.update(:requests, &[request | &1])

    case State.next(:scripts, request.role, @defaults[request.role]) do
      {:error, reason} -> {:error, reason}
      output -> {:ok, %{output: output, cost_usd: 0.25, input_tokens: 1000, output_tokens: 100}}
    end
  end
end
