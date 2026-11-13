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
      code_changed?: true,
      plan: [],
      # Raw REST payloads of pull request reviews: %{number => %{reviews: [], comments: []}}.
      reviews: %{},
      # Calls that fail until recovered: %{{call, number} => :before | :after}.
      failures: %{},
      # Functions run once when a call starts: %{{call, number} => fun}.
      hooks: %{},
      agent_hooks: %{},
      gate_hooks: %{},
      gate_calls: 0,
      commits: [],
      pushes: [],
      setups: 0,
      # Functions run once when a workspace call starts: %{call => fun}.
      workspace_hooks: %{},
      # What the next push answers instead of succeeding, if anything.
      push_failure: nil,
      # What `unpushed_changes/4` answers: blocks, or `{:error, message}`.
      unpushed: [],
      # What `head/2` answers, and the commits pushed and checked for secrets.
      head: {:ok, "fake-sha"},
      pushed_shas: [],
      checked_shas: []
    }
  end

  def get(key), do: Agent.get(__MODULE__, &Map.fetch!(&1, key))
  def put(key, value), do: Agent.update(__MODULE__, &Map.put(&1, key, value))
  def update(key, fun), do: Agent.update(__MODULE__, &Map.update!(&1, key, fun))

  @doc "Removes and returns the value under `sub` of the map at `key`, if any."
  def pop(key, sub) do
    Agent.get_and_update(__MODULE__, fn state ->
      {value, rest} = Map.pop(Map.fetch!(state, key), sub)
      {value, Map.put(state, key, rest)}
    end)
  end

  @doc """
  Runs the hook registered under `sub` of `key` once, in the calling process
  and outside the Agent, so it can call the fakes and the pipeline.
  """
  def run_hook(key, sub) do
    case pop(key, sub) do
      nil -> :ok
      fun -> fun.()
    end
  end

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
