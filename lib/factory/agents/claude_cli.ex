defmodule Factory.Agents.ClaudeCLI do
  @moduledoc """
  Runs agents with Claude Code in headless mode (`claude -p`).

  Each role gets only the tools it needs, and anything outside that list is
  denied instead of prompting, since nobody is there to answer. MCP servers and
  the user's own settings are left out so a run depends only on the repository.
  """
  @behaviour Factory.Agents
  alias Factory.Agents.Prompts
  alias Factory.{Secrets, Shell}

  @timeout :timer.minutes(60)

  @read_only ~w(Read Glob Grep) ++
               [
                 "Bash(git log:*)",
                 "Bash(git diff:*)",
                 "Bash(git show:*)",
                 "Bash(git status:*)",
                 "Bash(ls:*)"
               ]

  def tools(:reviewer), do: @read_only
  def tools(:planner), do: @read_only ++ ~w(Write Edit)
  def tools(:developer), do: ~w(Read Glob Grep Write Edit Bash)

  @impl true
  def run(request) do
    result =
      Shell.run("claude", args(request),
        cd: request.cwd,
        stdin: request.prompt,
        env: request[:env] || [],
        timeout: @timeout
      )

    # Secret values are replaced in the raw output, before it is parsed or cut.
    case Secrets.redact(request[:secrets], result) do
      {:ok, output} ->
        parse(output)

      {:error, {:exit, _status, output}} ->
        with({:ok, _} <- parse(output), do: {:error, Shell.tail(output, 2000)})

      {:error, reason} ->
        {:error, Shell.describe(reason)}
    end
  end

  def args(request) do
    budget =
      if b = request[:max_budget_usd], do: ["--max-budget-usd", Decimal.to_string(b)], else: []

    [
      "-p",
      "--model",
      request.model,
      "--effort",
      request.effort,
      "--output-format",
      "json",
      "--json-schema",
      Jason.encode!(request.schema),
      "--append-system-prompt",
      Prompts.system(),
      "--strict-mcp-config",
      "--setting-sources",
      "project,local",
      "--permission-mode",
      "acceptEdits",
      "--permission-prompts",
      "none",
      "--allowedTools",
      Enum.join(tools(request.role), ",")
    ] ++ budget
  end

  @doc "Reads the final result object Claude Code prints, ignoring any other output around it."
  def parse(output) do
    result =
      output
      |> String.split("\n", trim: true)
      |> Enum.reverse()
      |> Enum.find_value(fn line ->
        case Jason.decode(line) do
          {:ok, %{"type" => "result"} = result} -> result
          _ -> nil
        end
      end)

    case result do
      %{"is_error" => false, "structured_output" => %{} = structured} ->
        {:ok,
         %{
           output: structured,
           cost_usd: result["total_cost_usd"],
           input_tokens: input_tokens(result["usage"]),
           output_tokens: get_in(result, ["usage", "output_tokens"])
         }}

      %{} ->
        {:error, "#{result["subtype"]}: #{String.slice(to_string(result["result"]), 0, 1500)}"}

      nil ->
        {:error, "no result from claude: #{Shell.tail(output, 1500)}"}
    end
  end

  defp input_tokens(nil), do: nil

  defp input_tokens(usage) do
    Enum.sum(
      for key <- ~w(input_tokens cache_creation_input_tokens cache_read_input_tokens),
          do: usage[key] || 0
    )
  end
end
