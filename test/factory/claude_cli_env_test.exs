defmodule Factory.Agents.ClaudeCLIEnvTest do
  # Puts a fake `claude` first in the service's PATH.
  use ExUnit.Case, async: false

  alias Factory.Agents.ClaudeCLI
  alias Factory.Secrets.Bundle

  @value "dev-secret-value-1"

  setup do
    dir = Path.join(System.tmp_dir!(), "factory-claude-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = System.get_env("PATH")

    script = Path.join(dir, "claude")

    File.write!(script, """
    #!/bin/sh
    cat > /dev/null
    echo "starting with $API_KEY"
    printf '{"type":"result","is_error":false,"structured_output":{"status":"done","summary":"%s"}}\\n' "$API_KEY"
    """)

    File.chmod!(script, 0o755)
    System.put_env("PATH", dir <> ":" <> path)

    on_exit(fn ->
      System.put_env("PATH", path)
      File.rm_rf!(dir)
    end)

    %{dir: dir}
  end

  defp request(dir) do
    %{
      role: :developer,
      prompt: "work",
      schema: %{"type" => "object"},
      model: "claude-opus-5-5",
      effort: "high",
      cwd: dir,
      max_budget_usd: nil,
      env: [{"API_KEY", @value}],
      secrets: Bundle.new([%{name: "API_KEY", value: @value, checks_only: false}])
    }
  end

  test "claude gets the secret in its environment, and what it prints comes back filtered",
       %{dir: dir} do
    assert {:ok, %{output: output}} = ClaudeCLI.run(request(dir))
    assert output["summary"] == "[SECRET:API_KEY]"
  end

  test "a failed run is filtered before it is cut", %{dir: dir} do
    File.write!(Path.join(dir, "claude"), """
    #!/bin/sh
    cat > /dev/null
    echo "boom $API_KEY"
    exit 2
    """)

    assert {:error, reason} = ClaudeCLI.run(request(dir))
    assert reason =~ "[SECRET:API_KEY]"
    refute reason =~ @value
  end

  # A line of a multiline secret with a quote and a backslash, so its JSON form is not
  # the literal one, long enough to cross the 1500 characters an error is cut to.
  @line ~s(Zq"uo\\te-) <> String.duplicate("m4Xr", 300)
  @multiline "first-line-value\n" <> @line <> "\nlast"

  defp multiline_request(dir) do
    %{
      request(dir)
      | env: [],
        secrets: Bundle.new([%{name: "MULTI", value: @multiline, checks_only: false}])
    }
  end

  defp refute_piece(text) do
    refute text =~ String.slice(@line, 0, 12)
    refute text =~ String.slice(@line, 600, 12)
    refute text =~ String.slice(@line, -12, 12)
  end

  test "an error result with one line of a multiline secret keeps no piece of it", %{dir: dir} do
    result = %{
      "type" => "result",
      "is_error" => true,
      "subtype" => "error_during_execution",
      "result" => String.duplicate("y", 1000) <> @line
    }

    File.write!(Path.join(dir, "out.json"), Jason.encode!(result) <> "\n")

    File.write!(Path.join(dir, "claude"), """
    #!/bin/sh
    cat > /dev/null
    cat "#{Path.join(dir, "out.json")}"
    """)

    assert {:error, reason} = ClaudeCLI.run(multiline_request(dir))
    assert reason =~ "[SECRET:MULTI]"
    refute_piece(reason)

    # Decoded text is filtered even when the raw form was escaped in another way.
    raw = String.replace(Jason.encode!(result), "-", "\\u002d")
    assert {:error, reason} = ClaudeCLI.parse(raw, multiline_request(dir).secrets)
    assert reason =~ "[SECRET:MULTI]"
    refute_piece(reason)
  end

  test "a failed run that prints the line raw or escaped keeps no piece of it", %{dir: dir} do
    File.write!(Path.join(dir, "out.txt"), "boom #{@line}\n#{Jason.encode!(@line)}\n")

    File.write!(Path.join(dir, "claude"), """
    #!/bin/sh
    cat > /dev/null
    cat "#{Path.join(dir, "out.txt")}"
    exit 2
    """)

    assert {:error, reason} = ClaudeCLI.run(multiline_request(dir))
    refute_piece(reason)
  end
end
