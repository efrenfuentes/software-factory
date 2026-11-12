defmodule Factory.Agents.ClaudeCLITest do
  use ExUnit.Case, async: true
  alias Factory.Agents.ClaudeCLI

  test "reads the structured answer, cost and tokens from the result line" do
    output = """
    a warning on stderr
    {"type":"result","is_error":false,"structured_output":{"status":"done"},"total_cost_usd":0.5,"usage":{"input_tokens":2,"cache_read_input_tokens":8,"output_tokens":3}}
    """

    assert {:ok,
            %{output: %{"status" => "done"}, cost_usd: 0.5, input_tokens: 10, output_tokens: 3}} =
             ClaudeCLI.parse(output)
  end

  test "reports runs that end in error or without a structured answer" do
    assert {:error, "error_max_budget: spent"} =
             ClaudeCLI.parse(
               ~s({"type":"result","is_error":true,"subtype":"error_max_budget","result":"spent"})
             )

    assert {:error, "no result from claude: command not found"} =
             ClaudeCLI.parse("command not found")
  end

  test "the reviewer cannot write and only the developer can run arbitrary commands" do
    refute "Write" in ClaudeCLI.tools(:reviewer)
    refute "Bash" in ClaudeCLI.tools(:planner)
    assert "Bash" in ClaudeCLI.tools(:developer)
  end
end
