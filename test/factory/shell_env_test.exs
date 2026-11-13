defmodule Factory.ShellEnvTest do
  # Changes the service's environment and the application's configuration.
  use ExUnit.Case, async: false

  alias Factory.Secrets.{Bundle, Current}
  alias Factory.Shell
  alias Factory.Shell.Env

  setup do
    previous = Application.get_env(:factory, :env_passthrough)

    on_exit(fn ->
      System.delete_env("FACTORY_LEAK_TEST")
      System.delete_env("PASS_TEST_VAR")
      Current.delete()

      if previous,
        do: Application.put_env(:factory, :env_passthrough, previous),
        else: Application.delete_env(:factory, :env_passthrough)
    end)

    :ok
  end

  describe "names" do
    test "what children inherit or the factory sets is reserved, ignoring case" do
      Application.put_env(:factory, :env_passthrough, ["GH_TOKEN"])

      for name <- ~w(PATH path LC_ALL FACTORY_X ANTHROPIC_API_KEY GH_TOKEN gh_token CI
                     MIX_TEST_PARTITION XDG_CONFIG_HOME LD_PRELOAD CLAUDE_X FACTORY_STDIN) do
        assert Env.reserved?(name), name
      end

      refute Env.reserved?("DATABASE_URL")
      refute Env.reserved?("API_KEY")
    end

    test "an invalid name in the passthrough is ignored" do
      Application.put_env(:factory, :env_passthrough, ["GOOD_ONE", "1BAD", "A-B"])

      assert Env.passthrough() == ["GOOD_ONE"]
      assert Env.invalid_passthrough() == ["1BAD", "A-B"]
      assert Env.inherited?("GOOD_ONE")
      refute Env.reserved?("1BAD")
    end

    test "valid names" do
      assert Env.valid_name?("_A1")
      refute Env.valid_name?("1ABC")
      refute Env.valid_name?("A-B")
      refute Env.valid_name?(String.duplicate("A", 129))
      assert Env.valid_name?(String.duplicate("A", 128))
    end
  end

  describe "the environment of a child" do
    test "port_env/1 removes what is not inherited, except what is given" do
      System.put_env("FACTORY_LEAK_TEST", "leaked")
      env = Env.port_env([{"API_KEY", "v"}, {"GONE", nil}])

      assert {~c"FACTORY_LEAK_TEST", false} in env
      assert {~c"API_KEY", ~c"v"} in env
      assert {~c"GONE", false} in env
      refute Enum.any?(env, &match?({~c"PATH", _}, &1))
      refute Enum.any?(env, &match?({~c"HOME", _}, &1))

      env = Env.port_env([{"FACTORY_LEAK_TEST", "given"}])
      assert {~c"FACTORY_LEAK_TEST", ~c"given"} in env
      refute {~c"FACTORY_LEAK_TEST", false} in env
    end

    test "cmd_env/0 removes the same variables for System.cmd/3" do
      System.put_env("FACTORY_LEAK_TEST", "leaked")
      env = Env.cmd_env()

      assert {"FACTORY_LEAK_TEST", nil} in env
      refute Enum.any?(env, fn {name, _} -> name in ["PATH", "HOME"] end)
    end

    test "a command sees only the minimal environment, and the service's does not change" do
      System.put_env("FACTORY_LEAK_TEST", "leaked")
      System.put_env("PASS_TEST_VAR", "passed")
      Application.put_env(:factory, :env_passthrough, ["PASS_TEST_VAR"])
      before = System.get_env()

      assert {:ok, output} = Shell.sh("env", env: [{"GIVEN_VAR", "given"}])
      vars = output |> String.split("\n", trim: true) |> Map.new(&split_var/1)

      refute Map.has_key?(vars, "FACTORY_LEAK_TEST")
      assert vars["HOME"] == System.get_env("HOME")
      assert vars["PATH"] == System.get_env("PATH")
      assert vars["GIVEN_VAR"] == "given"
      assert vars["PASS_TEST_VAR"] == "passed"
      assert System.get_env() == before
    end

    test "the commands that end a command at its timeout get the minimal environment too" do
      dir = Path.join(System.tmp_dir!(), "factory-kill-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      path = System.get_env("PATH")

      for name <- ~w(pkill kill) do
        real = System.find_executable(name)
        script = Path.join(dir, name)
        File.write!(script, "#!/bin/sh\nenv > '#{dir}/#{name}.env'\nexec '#{real}' \"$@\"\n")
        File.chmod!(script, 0o755)
      end

      System.put_env("FACTORY_LEAK_TEST", "leaked")
      System.put_env("PATH", dir <> ":" <> path)

      on_exit(fn ->
        System.put_env("PATH", path)
        File.rm_rf!(dir)
      end)

      pidfile = Path.join(dir, "pid")

      assert {:error, :timeout} =
               Shell.sh("echo $$ > '#{pidfile}'; exec sleep 30", timeout: 200)

      for name <- ~w(pkill kill) do
        env = File.read!(Path.join(dir, "#{name}.env"))
        refute env =~ "FACTORY_LEAK_TEST"
        assert env =~ "PATH="
      end

      pid = pidfile |> File.read!() |> String.trim()
      assert gone?(pid, 20)
    end
  end

  describe "outputs cut during a stage" do
    test "no piece of a secret value survives the cut of describe/1" do
      value = "Zq8-secret-V4lue"
      assert String.length(value) == 16
      Current.put(Bundle.new([%{name: "API_KEY", value: value, checks_only: false}]))

      described = Shell.describe({:exit, 1, value <> String.duplicate("x", 5996)})

      refute described =~ String.slice(value, -4, 4)

      for size <- 4..16, start <- 0..(16 - size) do
        refute described =~ String.slice(value, start, size)
      end

      Current.delete()
      output = value <> String.duplicate("x", 5996)
      assert Shell.tail(output) == "…" <> String.slice(output, -6000, 6000)
    end
  end

  defp split_var(line) do
    case String.split(line, "=", parts: 2) do
      [name, value] -> {name, value}
      [name] -> {name, ""}
    end
  end

  defp gone?(_pid, 0), do: false

  defp gone?(pid, tries) do
    case System.cmd("kill", ["-0", pid], stderr_to_stdout: true) do
      {_, 0} ->
        Process.sleep(100)
        gone?(pid, tries - 1)

      _ ->
        true
    end
  end
end
