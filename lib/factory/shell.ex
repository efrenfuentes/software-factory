defmodule Factory.Shell do
  @moduledoc """
  Runs external commands with a timeout, optional stdin from a string and
  stderr merged into the output.

  Every command gets the minimal environment of `Factory.Shell.Env` plus the
  `:env` given, never the service's whole environment.
  """

  alias Factory.Shell.Env

  @default_timeout :timer.minutes(5)

  @type result ::
          {:ok, String.t()}
          | {:error, {:exit, non_neg_integer(), String.t()} | :timeout | :enoent}

  @spec run(String.t(), [String.t()], keyword()) :: result
  def run(cmd, args, opts \\ []) do
    case System.find_executable(cmd) do
      nil -> {:error, :enoent}
      exe -> with_stdin(opts[:stdin], &exec(exe, args, &1, opts))
    end
  end

  @doc "Runs a shell command line (`sh -c`)."
  def sh(line, opts \\ []), do: run("sh", ["-c", line], opts)

  defp with_stdin(nil, fun), do: fun.("/dev/null")

  defp with_stdin(content, fun) do
    path = Path.join(System.tmp_dir!(), "factory-stdin-#{System.unique_integer([:positive])}")
    File.write!(path, content)

    try do
      fun.(path)
    after
      File.rm(path)
    end
  end

  defp exec(exe, args, stdin_path, opts) do
    # The child gets the minimal environment, never the service's whole one.
    env = Env.port_env([{"FACTORY_STDIN", stdin_path} | Keyword.get(opts, :env, [])])

    port_opts = [
      :binary,
      :exit_status,
      :stderr_to_stdout,
      :hide,
      args: ["-c", ~s(exec "$0" "$@" < "$FACTORY_STDIN"), exe | args],
      env: env
    ]

    port_opts = if cd = opts[:cd], do: [{:cd, cd} | port_opts], else: port_opts
    port = Port.open({:spawn_executable, System.find_executable("sh")}, port_opts)
    deadline = System.monotonic_time(:millisecond) + Keyword.get(opts, :timeout, @default_timeout)
    collect(port, [], deadline)
  end

  defp collect(port, acc, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} ->
        collect(port, [data | acc], deadline)

      {^port, {:exit_status, 0}} ->
        {:ok, output(acc)}

      {^port, {:exit_status, status}} ->
        {:error, {:exit, status, output(acc)}}
    after
      remaining ->
        kill(port)
        {:error, :timeout}
    end
  end

  defp output(acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  defp kill(port) do
    with {:os_pid, pid} <- Port.info(port, :os_pid) do
      env = Env.cmd_env()
      System.cmd("pkill", ["-TERM", "-P", to_string(pid)], stderr_to_stdout: true, env: env)
      System.cmd("kill", ["-TERM", to_string(pid)], stderr_to_stdout: true, env: env)
    end

    # The port may close by itself once the process dies, between the check and the close.
    try do
      Port.close(port)
    rescue
      ArgumentError -> :ok
    end
  end

  @doc "Human-readable description of a failed `run/3`."
  def describe({:exit, status, output}), do: "exit #{status}: #{tail(output)}"
  def describe(:timeout), do: "timed out"
  def describe(:enoent), do: "command not found"
  def describe(other), do: inspect(other)

  @doc """
  The last `chars` characters of a long output. During a stage, the project's
  secret values are replaced first, so no piece of one survives the cut.
  """
  def tail(output, chars \\ 6000) do
    output = Factory.Secrets.Current.redact(output)
    if String.length(output) > chars, do: "…" <> String.slice(output, -chars, chars), else: output
  end
end
