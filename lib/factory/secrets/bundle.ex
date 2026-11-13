defmodule Factory.Secrets.Bundle do
  @moduledoc """
  A project's decrypted secrets, held in memory while a stage runs.

  `inspect/1` shows only the names. `fragments` are the texts the filter looks
  for, each with the name it stands for, longest first: the value, its JSON
  escaped form and, for a multiline value, each trimmed line of at least 8
  characters that is not a PEM armor line.
  """

  @derive {Inspect, only: [:names]}
  defstruct names: [], entries: [], fragments: []

  @type entry :: %{name: String.t(), value: String.t(), checks_only: boolean()}
  @type t :: %__MODULE__{
          names: [String.t()],
          entries: [entry],
          fragments: [{String.t(), String.t()}]
        }

  @min_fragment 8

  def empty, do: %__MODULE__{}

  @spec new([entry]) :: t()
  def new(entries) do
    entries = Enum.sort_by(entries, & &1.name)

    fragments =
      entries
      |> Enum.flat_map(fn %{name: name, value: value} ->
        for text <- texts(value), byte_size(text) >= @min_fragment, do: {text, name}
      end)
      |> Enum.uniq_by(fn {text, _} -> text end)
      |> Enum.sort_by(fn {text, _} -> byte_size(text) end, :desc)

    %__MODULE__{names: Enum.map(entries, & &1.name), entries: entries, fragments: fragments}
  end

  defp texts(value) do
    json = value |> Jason.encode!() |> String.slice(1..-2//1)
    lines = if String.contains?(value, "\n"), do: lines(value), else: []
    [value, json | lines]
  end

  defp lines(value) do
    for line <- String.split(value, "\n"),
        line = String.trim(line),
        not armor?(line),
        do: line
  end

  defp armor?(line), do: Regex.match?(~r/^-----(BEGIN|END) [^-]*-----$/, line)
end
