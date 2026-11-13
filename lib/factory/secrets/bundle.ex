defmodule Factory.Secrets.Bundle do
  @moduledoc """
  A project's decrypted secrets, held in memory while a stage runs.

  `inspect/1` shows only the names. `fragments` are the texts the filter looks
  for, each with the name it stands for, longest first: the value, its JSON
  escaped form and, for a multiline value, each trimmed line of at least 8
  characters (graphemes) that is not a PEM armor line, with its JSON escaped form.
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
        for text <- texts(value), do: {text, name}
      end)
      |> Enum.uniq_by(fn {text, _} -> text end)
      |> Enum.sort_by(fn {text, _} -> byte_size(text) end, :desc)

    %__MODULE__{names: Enum.map(entries, & &1.name), entries: entries, fragments: fragments}
  end

  # The whole value and its JSON form always; the lines and their JSON forms only
  # when they have at least 8 characters (graphemes, not bytes).
  defp texts(value) do
    lines = if String.contains?(value, "\n"), do: lines(value), else: []

    [value | lines]
    |> Enum.flat_map(&[&1, json(&1)])
    |> Enum.uniq()
  end

  defp json(text), do: text |> Jason.encode!() |> String.slice(1..-2//1)

  defp lines(value) do
    for line <- String.split(value, "\n"),
        line = String.trim(line),
        String.length(line) >= @min_fragment,
        not armor?(line),
        do: line
  end

  defp armor?(line), do: Regex.match?(~r/^-----(BEGIN|END) [^-]*-----$/, line)
end
