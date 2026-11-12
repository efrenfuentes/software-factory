defmodule Factory.Shell do
  @moduledoc """
  Runs external commands with a timeout, optional stdin from a string and
  stderr merged into the output.
  """

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
    env =
      for {key, value} <- [{"FACTORY_STDIN", stdin_path} | Keyword.get(opts, :env, [])] do
        {String.to_charlist(key), value && String.to_charlist(value)}
      end

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
      System.cmd("pkill", ["-TERM", "-P", to_string(pid)], stderr_to_stdout: true)
      System.cmd("kill", ["-TERM", to_string(pid)], stderr_to_stdout: true)
    end

    if Port.info(port), do: Port.close(port)
  end

  @doc "Human-readable description of a failed `run/3`."
  def describe({:exit, status, output}), do: "exit #{status}: #{tail(output)}"
  def describe(:timeout), do: "timed out"
  def describe(:enoent), do: "command not found"
  def describe(other), do: inspect(other)

  @doc "The last `chars` characters of a long output."
  def tail(output, chars \\ 6000) do
    if String.length(output) > chars, do: "…" <> String.slice(output, -chars, chars), else: output
  end
end
