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
end
