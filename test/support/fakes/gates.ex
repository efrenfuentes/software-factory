defmodule Factory.Fakes.Gates do
  @moduledoc "Gates that pass unless scripted with `script/1`."
  @behaviour Factory.Gates
  alias Factory.Fakes.State

  def script(results), do: State.put(:gates, results)

  @doc "Runs `fun` once when the `n`-th check from now (counting from 1) starts."
  def during(n, fun) do
    at = State.get(:gate_calls) + n
    State.update(:gate_hooks, &Map.put(&1, at, fun))
  end

  @impl true
  def setup(_project, _issue, _path), do: :ok
  @impl true
  def check(_project, _issue, _path) do
    State.update(:gate_calls, &(&1 + 1))
    State.run_hook(:gate_hooks, State.get(:gate_calls))
    State.next(:gates, nil, :ok)
  end
end
