defmodule Factory.Agents.CodexCLITest do
  use ExUnit.Case, async: true
  alias Factory.Agents.{CodexCLI, Prompts}

  @events """
  a warning on stderr
  {"type":"thread.started","thread_id":"t1"}
  {"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"Checking the diff."}}
  {"type":"item.completed","item":{"id":"item_1","type":"agent_message","text":"{\\"verdict\\":\\"approve\\"}"}}
  {"type":"turn.completed","usage":{"input_tokens":50,"cached_input_tokens":30,"output_tokens":7}}
  """

  test "reads the answer file and the token usage, with no cost" do
    assert {:ok,
            %{
              output: %{"verdict" => "changes_requested"},
              cost_usd: nil,
              input_tokens: 50,
              output_tokens: 7
            }} = CodexCLI.parse(@events, ~s({"verdict":"changes_requested"}))
  end

  test "falls back to the last message in the events when no answer file was written" do
    assert {:ok, %{output: %{"verdict" => "approve"}}} = CodexCLI.parse(@events, nil)
  end

  test "reports failed turns and answers that are not the structured one" do
    assert {:error, "codex failed: usage limit reached"} =
             CodexCLI.parse(
               ~s({"type":"turn.failed","error":{"message":"usage limit reached"}}),
               nil
             )

    assert {:error, "no structured answer from codex: " <> _} =
             CodexCLI.parse("command not found", nil)
  end

  test "a secret line in a decoded failure or message is replaced before it is shown" do
    line = ~s(Zq"uo\\te-) <> String.duplicate("m4Xr", 300)

    secrets =
      Factory.Secrets.Bundle.new([
        %{name: "MULTI", value: "first-line-value\n#{line}\nlast", checks_only: false}
      ])

    # Escaped in a way the raw filter does not know (`\u002d` for `-`).
    escaped = fn text -> text |> Jason.encode!() |> String.replace("-", "\\u002d") end
    failed = ~s({"type":"turn.failed","error":{"message":#{escaped.(line)}}})

    assert {:error, reason} = CodexCLI.parse(failed, nil, secrets)
    assert reason == "codex failed: [SECRET:MULTI]"

    message =
      ~s({"type":"item.completed","item":{"type":"agent_message","text":#{escaped.("not json " <> line)}}})

    assert {:error, reason} = CodexCLI.parse(message, nil, secrets)
    assert reason =~ "[SECRET:MULTI]"
    refute reason =~ String.slice(line, 0, 12)
    refute reason =~ String.slice(line, -12, 12)
  end

  test "runs read-only, without the user's configuration, on the chosen model and effort" do
    args = CodexCLI.args(%{model: "gpt-6-astra", effort: "high"}, "/s.json", "/a.json")

    assert ["exec", "--model", "gpt-6-astra", "-c", "model_reasoning_effort=high" | _] = args

    assert ["--sandbox", "read-only"] =
             args |> Enum.drop_while(&(&1 != "--sandbox")) |> Enum.take(2)

    assert "--ignore-user-config" in args
  end

  test "only runs the reviewer" do
    assert {:error, "Codex can only run the reviewer, not the developer"} =
             CodexCLI.run(%{role: :developer})
  end

  test "makes every object in a schema closed with all properties required" do
    schema = %{
      type: "object",
      required: ["a"],
      properties: %{
        a: %{type: "string"},
        b: %{type: "array", items: %{type: "object", properties: %{c: %{type: "string"}}}}
      }
    }

    assert %{
             "additionalProperties" => false,
             "required" => ["a", "b"],
             "properties" => %{
               "b" => %{"items" => %{"additionalProperties" => false, "required" => ["c"]}}
             }
           } = CodexCLI.strict(schema)

    assert %{"required" => required} = CodexCLI.strict(Prompts.review_schema())
    assert Enum.sort(required) == ~w(blocking minor summary verdict)
  end
end
