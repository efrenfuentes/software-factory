defmodule Factory.ShellTest do
  use ExUnit.Case, async: true
  alias Factory.Shell

  test "passes stdin, the working directory and the environment" do
    assert {:ok, "hello"} = Shell.run("cat", [], stdin: "hello")
    assert {:ok, output} = Shell.sh("pwd; echo $FOO", cd: "/usr", env: [{"FOO", "bar"}])
    assert output == "/usr\nbar\n"
  end

  test "reports the exit status with stdout and stderr" do
    assert {:error, {:exit, 3, "out\nerr\n"}} = Shell.sh("echo out; echo err >&2; exit 3")
    assert {:error, :enoent} = Shell.run("no-such-command-here", [])
  end

  test "stops commands that run past their timeout" do
    assert {:error, :timeout} = Shell.sh("sleep 5", timeout: 200)
  end
end
