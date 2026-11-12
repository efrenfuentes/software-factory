defmodule Factory.Fakes.Gates do
  @moduledoc "Gates that pass unless scripted with `script/1`."
  @behaviour Factory.Gates
  alias Factory.Fakes.State

  def script(results), do: State.put(:gates, results)

  @impl true
  def setup(_project, _issue, _path), do: :ok
  @impl true
  def check(_project, _issue, _path), do: State.next(:gates, nil, :ok)
end
