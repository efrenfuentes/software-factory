defmodule Factory.Agents.CodexCLI do
  @moduledoc """
  Runs the Reviewer with Codex in headless mode (`codex exec`).

  The read-only sandbox lets it read the repository and run commands such as
  `git diff`, but not change anything. The user's Codex configuration and rules
  are left out so a run depends only on the repository. Codex reports tokens but
  not what the run cost, and has no spending cap.
  """
  @behaviour Factory.Agents
  alias Factory.Agents.Prompts
  alias Factory.{Secrets, Shell}

  @timeout :timer.minutes(60)

  @impl true
  def run(%{role: :reviewer} = request) do
    dir = Path.join(System.tmp_dir!(), "factory-codex-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    schema_path = Path.join(dir, "schema.json")
    answer_path = Path.join(dir, "answer.json")
    File.write!(schema_path, Jason.encode!(strict(request.schema)))

    try do
      result =
        Shell.run("codex", args(request, schema_path, answer_path),
          cd: request.cwd,
          stdin: Prompts.system() <> "\n" <> request.prompt,
          env: request[:env] || [],
          timeout: @timeout
        )

      # Secret values are replaced in the raw output and answer, before they are parsed or
      # cut, and again in what is decoded from them.
      secrets = request[:secrets]

      case Secrets.redact(secrets, result) do
        {:ok, events} ->
          parse(events, Secrets.redact(secrets, read(answer_path)), secrets)

        {:error, {:exit, _status, events}} ->
          {:error, Secrets.redact(secrets, failure(events)) || Shell.tail(events, 2000)}

        {:error, reason} ->
          {:error, Shell.describe(reason)}
      end
    after
      File.rm_rf(dir)
    end
  end

  def run(%{role: role}), do: {:error, "Codex can only run the reviewer, not the #{role}"}

  def args(request, schema_path, answer_path) do
    [
      "exec",
      "--model",
      request.model,
      "-c",
      "model_reasoning_effort=#{request.effort}",
      "--sandbox",
      "read-only",
      "--ignore-user-config",
      "--ignore-rules",
      "--ephemeral",
      "--json",
      "--output-schema",
      schema_path,
      "--output-last-message",
      answer_path,
      "-"
    ]
  end

  @doc """
  Reads the answer Codex wrote as its last message and the token usage from its
  event stream. `answer` is nil when Codex wrote none. The values of `secrets`
  are replaced in the texts decoded from the events, before any is shown.
  """
  def parse(events, answer, secrets \\ nil) do
    events = events |> decode_lines() |> then(&Secrets.redact(secrets, &1))
    usage = Enum.find_value(events, &(&1["type"] == "turn.completed" && &1["usage"])) || %{}

    with nil <- failure(events),
         {:ok, %{} = output} <- Jason.decode(answer || last_message(events) || "") do
      {:ok,
       %{
         output: output,
         cost_usd: nil,
         input_tokens: usage["input_tokens"],
         output_tokens: usage["output_tokens"]
       }}
    else
      reason when is_binary(reason) -> {:error, reason}
      _ -> {:error, "no structured answer from codex: #{inspect(answer || last_message(events))}"}
    end
  end

  @doc """
  Codex only accepts schemas where every object lists all its properties as
  required and allows no others.
  """
  def strict(schema) do
    schema |> Jason.encode!() |> Jason.decode!() |> strict_node()
  end

  defp strict_node(%{"type" => "object", "properties" => properties} = node) do
    node
    |> Map.put(
      "properties",
      Map.new(properties, fn {key, value} -> {key, strict_node(value)} end)
    )
    |> Map.put("required", Map.keys(properties))
    |> Map.put("additionalProperties", false)
  end

  defp strict_node(%{"items" => items} = node), do: Map.put(node, "items", strict_node(items))
  defp strict_node(node), do: node

  defp failure(events) when is_binary(events), do: events |> decode_lines() |> failure()

  defp failure(events) do
    Enum.find_value(events, fn
      %{"type" => "turn.failed", "error" => %{"message" => message}} -> "codex failed: #{message}"
      %{"type" => "error", "message" => message} -> "codex failed: #{message}"
      _ -> nil
    end)
  end

  defp last_message(events) do
    events
    |> Enum.reverse()
    |> Enum.find_value(fn
      %{"type" => "item.completed", "item" => %{"type" => "agent_message", "text" => text}} ->
        text

      _ ->
        nil
    end)
  end

  # Stderr is mixed into the output, so lines that are not events are skipped.
  defp decode_lines(output) do
    for line <- String.split(output, "\n", trim: true),
        {:ok, %{} = event} <- [Jason.decode(line)],
        do: event
  end

  defp read(path) do
    case File.read(path) do
      {:ok, content} when content != "" -> content
      _ -> nil
    end
  end
end
