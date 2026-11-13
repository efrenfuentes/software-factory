defmodule Factory.Secrets.Current do
  @moduledoc """
  The secrets of the stage running in this process.

  `Factory.Pipeline.Stages.run/1` puts them here for the length of a stage, so
  that `Factory.Shell.tail/2` can replace their values before cutting an output
  whose caller does not know the project (the errors of `Workspace.Git` and
  `GitHub.CLI`). Outside a stage there is nothing here and nothing changes.
  """
  alias Factory.Secrets

  @key {__MODULE__, :bundle}

  def put(bundle), do: Process.put(@key, bundle)
  def delete, do: Process.delete(@key)
  def get, do: Process.get(@key)

  @doc "Replaces the values of the current secrets in `text`."
  def redact(text), do: Secrets.redact(get(), text)
end
