defmodule FactoryWeb.Browser do
  @moduledoc """
  A headless Chromium driven over the DevTools protocol, for the few tests that
  need what only a browser has: the DOM properties (`value`, `checked`) that a
  LiveView patch leaves in the fields, which `Phoenix.LiveViewTest` cannot see.

  It has no dependencies: a minimal WebSocket client over `:gen_tcp` speaks to
  the browser. The browser is `FACTORY_TEST_BROWSER`, else a Chromium in `PATH`,
  else one installed by Playwright in `~/.cache/ms-playwright`; without any,
  `test/test_helper.exs` excludes the `:browser` tests and says so.

  The page loads the Phoenix and LiveView clients from `deps/` (`connect_live/1`)
  instead of `priv/static/assets/js/app.js`, which the test environment does not
  build: they are the same client code `app.js` bundles.
  """
  use GenServer

  @timeout 15_000

  @doc "The Chromium to use, or nil."
  def executable do
    case System.get_env("FACTORY_TEST_BROWSER") do
      path when is_binary(path) and path != "" ->
        path

      _ ->
        Enum.find_value(
          ~w(chromium chromium-browser google-chrome google-chrome-stable chrome-headless-shell),
          &System.find_executable/1
        ) || playwright()
    end
  end

  defp playwright do
    home = System.user_home() || "/nonexistent"

    [
      "chromium_headless_shell-*/chrome-headless-shell-linux64/chrome-headless-shell",
      "chromium-*/chrome-linux*/chrome"
    ]
    |> Enum.flat_map(&Path.wildcard(Path.join([home, ".cache", "ms-playwright", &1])))
    |> Enum.sort(:desc)
    |> List.first()
  end

  def start_link(executable), do: GenServer.start_link(__MODULE__, executable)

  @doc "Opens `url` and waits until the page has loaded."
  def visit(browser, url) do
    command(browser, "Page.navigate", %{url: url})
    wait_until(browser, "document.readyState === 'complete'")
  end

  @doc "Starts the LiveView client on the current page and waits until it is connected."
  def connect_live(browser) do
    for file <-
          ~w(phoenix/priv/static/phoenix.js phoenix_live_view/priv/static/phoenix_live_view.js) do
      eval(browser, File.read!(Path.join(Mix.Project.deps_path(), file)) <> "\n;true")
    end

    eval(browser, """
    window.liveSocket = new LiveView.LiveSocket("/live", Phoenix.Socket, {
      params: {_csrf_token: document.querySelector("meta[name='csrf-token']").getAttribute("content")}
    });
    window.liveSocket.connect();
    true
    """)

    wait_until(browser, "!!document.querySelector('[data-phx-main].phx-connected')")
  end

  @doc "Evaluates `expression` in the page and returns its value."
  def eval(browser, expression) do
    result =
      command(browser, "Runtime.evaluate", %{
        expression: expression,
        returnByValue: true,
        awaitPromise: true
      })

    case result do
      %{"exceptionDetails" => details} -> raise "JavaScript error: #{inspect(details)}"
      %{"result" => result} -> result["value"]
    end
  end

  @doc "Waits until `expression` is truthy in the page, or fails."
  def wait_until(browser, expression, timeout \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    poll(browser, expression, deadline)
  end

  defp poll(browser, expression, deadline) do
    cond do
      eval(browser, expression) ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        raise ExUnit.AssertionError,
          message:
            "timed out waiting for #{expression}\n\n#{eval(browser, "document.body ? document.body.innerHTML : ''")}"

      true ->
        Process.sleep(50)
        poll(browser, expression, deadline)
    end
  end

  @doc "Types `text` into the element, as a person would: focus, then key input."
  def type(browser, selector, text) do
    eval(browser, "document.querySelector(#{Jason.encode!(selector)}).focus(); true")
    command(browser, "Input.insertText", %{text: text})
    :ok
  end

  @doc "Clicks the element."
  def click(browser, selector) do
    eval(browser, "document.querySelector(#{Jason.encode!(selector)}).click(); true")
    :ok
  end

  defp command(browser, method, params),
    do: GenServer.call(browser, {:command, method, params}, @timeout + 1_000)

  ## Server

  @impl true
  def init(executable) do
    Process.flag(:trap_exit, true)
    dir = Path.join(System.tmp_dir!(), "factory-browser-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    port =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        line: 4096,
        args: [
          "--headless",
          "--no-sandbox",
          "--disable-gpu",
          "--disable-dev-shm-usage",
          "--no-first-run",
          "--remote-debugging-port=0",
          "--user-data-dir=#{dir}",
          "about:blank"
        ]
      ])

    {:os_pid, os_pid} = Port.info(port, :os_pid)
    url = await_url(port, System.monotonic_time(:millisecond) + @timeout)
    {socket, buffer} = connect(url)

    state = %{
      port: port,
      os_pid: os_pid,
      dir: dir,
      socket: socket,
      buffer: buffer,
      id: 0,
      session: nil
    }

    {%{"targetId" => target}, state} =
      request(state, "Target.createTarget", %{url: "about:blank"})

    {%{"sessionId" => session}, state} =
      request(state, "Target.attachToTarget", %{targetId: target, flatten: true})

    {:ok, %{state | session: session}}
  end

  @impl true
  def handle_call({:command, method, params}, _from, state) do
    {result, state} = request(state, method, params)
    {:reply, result, state}
  end

  @impl true
  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    :gen_tcp.close(state.socket)
    System.cmd("kill", ["-9", to_string(state.os_pid)], stderr_to_stdout: true)
    File.rm_rf(state.dir)
  end

  defp await_url(port, deadline) do
    receive do
      {^port, {:data, {_eol, line}}} ->
        case Regex.run(~r{DevTools listening on (ws://\S+)}, line) do
          [_, url] -> url
          nil -> await_url(port, deadline)
        end

      {^port, {:exit_status, status}} ->
        raise "the browser exited with status #{status} before it was ready"
    after
      max(deadline - System.monotonic_time(:millisecond), 0) ->
        raise "the browser did not start in #{@timeout} ms"
    end
  end

  ## A minimal WebSocket client (RFC 6455): text frames, masked as a client must.

  defp connect(url) do
    %URI{host: host, port: port, path: path} = URI.parse(url)

    {:ok, socket} =
      :gen_tcp.connect(String.to_charlist(host), port, [:binary, active: false], @timeout)

    key = Base.encode64(:crypto.strong_rand_bytes(16))

    :ok =
      :gen_tcp.send(socket, [
        "GET #{path} HTTP/1.1\r\nHost: #{host}:#{port}\r\nUpgrade: websocket\r\n",
        "Connection: Upgrade\r\nSec-WebSocket-Key: #{key}\r\nSec-WebSocket-Version: 13\r\n\r\n"
      ])

    {headers, rest} = read_headers(socket, "")
    "HTTP/1.1 101" <> _ = headers
    {socket, rest}
  end

  defp read_headers(socket, acc) do
    case :binary.split(acc, "\r\n\r\n") do
      [headers, rest] ->
        {headers, rest}

      [_] ->
        {:ok, data} = :gen_tcp.recv(socket, 0, @timeout)
        read_headers(socket, acc <> data)
    end
  end

  defp request(state, method, params) do
    id = state.id + 1
    message = %{id: id, method: method, params: params}
    message = if state.session, do: Map.put(message, :sessionId, state.session), else: message
    send_frame(state.socket, 0x1, Jason.encode!(message))
    await_reply(%{state | id: id}, id)
  end

  defp await_reply(state, id) do
    {payload, state} = read_message(state, "")

    case Jason.decode!(payload) do
      %{"id" => ^id, "error" => error} -> raise "#{inspect(error)}"
      %{"id" => ^id, "result" => result} -> {result, state}
      _event -> await_reply(state, id)
    end
  end

  defp read_message(state, acc) do
    {fin, opcode, payload, state} = read_frame(state)

    case opcode do
      0x9 ->
        send_frame(state.socket, 0xA, payload)
        read_message(state, acc)

      0xA ->
        read_message(state, acc)

      0x8 ->
        raise "the browser closed the connection"

      _text_binary_or_continuation when fin == 1 ->
        {acc <> payload, state}

      _ ->
        read_message(state, acc <> payload)
    end
  end

  defp read_frame(state) do
    case parse_frame(state.buffer) do
      {:ok, fin, opcode, payload, rest} ->
        {fin, opcode, payload, %{state | buffer: rest}}

      :more ->
        {:ok, data} = :gen_tcp.recv(state.socket, 0, @timeout)
        read_frame(%{state | buffer: state.buffer <> data})
    end
  end

  # Frames from a server are not masked.
  defp parse_frame(<<fin::1, _::3, opcode::4, 0::1, len::7, rest::binary>>) do
    with {:ok, len, rest} <- payload_length(len, rest),
         <<payload::binary-size(^len), rest::binary>> <- rest do
      {:ok, fin, opcode, payload, rest}
    else
      _ -> :more
    end
  end

  defp parse_frame(_buffer), do: :more

  defp payload_length(126, <<len::16, rest::binary>>), do: {:ok, len, rest}
  defp payload_length(127, <<len::64, rest::binary>>), do: {:ok, len, rest}
  defp payload_length(len, rest) when len < 126, do: {:ok, len, rest}
  defp payload_length(_len, _rest), do: :more

  defp send_frame(socket, opcode, payload) do
    size = byte_size(payload)

    length =
      cond do
        size < 126 -> <<1::1, size::7>>
        size < 65_536 -> <<1::1, 126::7, size::16>>
        true -> <<1::1, 127::7, size::64>>
      end

    key = :crypto.strong_rand_bytes(4)
    mask = :binary.copy(key, div(size, 4) + 1) |> binary_part(0, size)

    :ok =
      :gen_tcp.send(socket, [<<1::1, 0::3, opcode::4>>, length, key, :crypto.exor(payload, mask)])
  end
end
