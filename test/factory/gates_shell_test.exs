defmodule Factory.GatesShellTest do
  use ExUnit.Case, async: true

  alias Factory.Gates
  alias Factory.Pipeline.Issue
  alias Factory.Projects.Project
  alias Factory.Secrets.Bundle

  test "the checks get every secret, and their output comes back without the values" do
    project = %Project{
      app_type: "elixir",
      setup_cmd: "true",
      lint_cmd: "true",
      test_cmd: "printenv API_KEY CHECK_ONLY; echo $MIX_TEST_PARTITION; exit 1",
      secrets:
        Bundle.new([
          %{name: "API_KEY", value: "api-key-value-1", checks_only: false},
          %{name: "CHECK_ONLY", value: "check-only-value-2", checks_only: true}
        ])
    }

    assert :ok = Gates.Shell.setup(project, %Issue{number: 7}, System.tmp_dir!())
    assert {:error, out} = Gates.Shell.check(project, %Issue{number: 7}, System.tmp_dir!())

    assert out =~ "[SECRET:API_KEY]"
    assert out =~ "[SECRET:CHECK_ONLY]"
    assert out =~ "_issue7"
    refute out =~ "api-key-value-1"
    refute out =~ "check-only-value-2"
  end
end
