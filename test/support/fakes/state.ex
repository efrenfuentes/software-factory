defmodule Factory.Fakes.State do
  @moduledoc "Shared scripted state for the fakes that stand in for GitHub, git, the gates and the agents."
  use Agent

  def start_link(_ \\ []), do: Agent.start_link(fn -> initial() end, name: __MODULE__)
  def reset, do: Agent.update(__MODULE__, fn _ -> initial() end)

  defp initial do
    %{
      scripts: %{},
      gates: [],
      requests: [],
      comments: [],
      labels: %{},
      issues: %{},
      listed: [],
      prs: %{},
      code_changed?: true
    }
  end

  def get(key), do: Agent.get(__MODULE__, &Map.fetch!(&1, key))
  def put(key, value), do: Agent.update(__MODULE__, &Map.put(&1, key, value))
  def update(key, fun), do: Agent.update(__MODULE__, &Map.update!(&1, key, fun))

  @doc "Takes the next scripted value of a queue; the last one repeats forever."
  def next(key, sub, default) do
    Agent.get_and_update(__MODULE__, fn state ->
      queues = Map.fetch!(state, key)
      queue = if sub, do: Map.get(queues, sub, []), else: queues

      {value, rest} =
        case queue do
          [] -> {default, []}
          [only] -> {only, [only]}
          [head | tail] -> {head, tail}
        end

      queues = if sub, do: Map.put(queues, sub, rest), else: rest
      {value, Map.put(state, key, queues)}
    end)
  end
end
