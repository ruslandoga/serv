defmodule Serv.ServerTest do
  use ExUnit.Case

  defmodule Echo do
    use Serv.Handler

    @impl true
    def handle_connection(socket, state) do
      {:ok, data} = :socket.recv(socket, 0)
      :socket.send(socket, data)
      {:close, state}
    end
  end

  defmodule LongEcho do
    use Serv.Handler

    @impl true
    def handle_data(data, socket, state) do
      :socket.send(socket, data)
      {:continue, state}
    end
  end

  defmodule Whoami do
    use Serv.Handler

    @impl true
    def handle_connection(socket, state) do
      :socket.send(socket, :erlang.pid_to_list(self()))
      {:continue, state}
    end
  end

  test "should handle multiple connections as expected" do
    {:ok, _, port} = start_handler(Echo)
    {:ok, client} = :gen_tcp.connect(:localhost, port, active: false)
    {:ok, other_client} = :gen_tcp.connect(:localhost, port, active: false)

    :ok = :gen_tcp.send(client, "HELLO")
    :ok = :gen_tcp.send(other_client, "BONJOUR")

    # Invert the order to ensure we handle concurrently
    assert :gen_tcp.recv(other_client, 0) == {:ok, ~c"BONJOUR"}
    assert :gen_tcp.recv(client, 0) == {:ok, ~c"HELLO"}
  end

  describe "min/max acceptors handling" do
    @tag :skip
    test "should properly handle too many connections by queueing" do
      {:ok, _, port} = start_handler(LongEcho, min_acceptors: 1, max_acceptors: 1)
      {:ok, client} = :gen_tcp.connect(:localhost, port, active: false)
      {:ok, other_client} = :gen_tcp.connect(:localhost, port, active: false)

      :ok = :gen_tcp.send(client, "HELLO")
      :ok = :gen_tcp.send(other_client, "BONJOUR")

      # Give things enough time to send if they were going to
      Process.sleep(100)

      # Ensure that we haven't received anything on the second connection yet
      assert :gen_tcp.recv(other_client, 0, 10) == {:error, :timeout}
      assert :gen_tcp.recv(client, 0) == {:ok, ~c"HELLO"}

      # Close our first connection to make room for the second to be accepted
      :gen_tcp.close(client)

      # Give things enough time to send if they were going to
      Process.sleep(100)

      # Ensure that the second connection unblocked
      assert :gen_tcp.recv(other_client, 0) == {:ok, ~c"BONJOUR"}
      :gen_tcp.close(other_client)
    end

    @tag :skip
    test "should properly handle too many connections if none close in time" do
      {:ok, _, port} =
        start_handler(LongEcho,
          min_acceptors: 1,
          max_acceptors: 1,
          max_acceptors_retry_wait: 100
        )

      {:ok, client} = :gen_tcp.connect(:localhost, port, active: false)
      {:ok, other_client} = :gen_tcp.connect(:localhost, port, active: false)

      :ok = :gen_tcp.send(client, "HELLO")
      :ok = :gen_tcp.send(other_client, "BONJOUR")

      # Give things enough time to send if they were going to
      Process.sleep(100)

      # Ensure that we haven't received anything on the second connection yet
      assert :gen_tcp.recv(other_client, 0, 10) == {:error, :timeout}
      assert :gen_tcp.recv(client, 0) == {:ok, ~c"HELLO"}

      # Give things enough time for the second connection to time out
      Process.sleep(500)

      # Ensure that the first connection is still open and the second connection closed
      :ok = :gen_tcp.send(client, "HELLO")
      assert :gen_tcp.recv(client, 0) == {:ok, ~c"HELLO"}
      assert :gen_tcp.recv(other_client, 0) == {:error, :closed}
      :gen_tcp.close(other_client)
    end
  end

  test "should enumerate active acceptor processes" do
    {:ok, server_pid, port} = start_handler(Whoami, min_acceptors: 1)
    {:ok, client} = :gen_tcp.connect(:localhost, port, active: false)
    {:ok, other_client} = :gen_tcp.connect(:localhost, port, active: false)

    {:ok, pid_1} = :gen_tcp.recv(client, 0)
    {:ok, pid_2} = :gen_tcp.recv(other_client, 0)
    pid_1 = :erlang.list_to_pid(pid_1)
    pid_2 = :erlang.list_to_pid(pid_2)

    pids = Serv.acceptors(server_pid)
    assert pid_1 in pids
    assert pid_2 in pids

    :gen_tcp.close(client)
    Process.sleep(100)
    refute pid_1 in Serv.acceptors(server_pid)

    :gen_tcp.close(other_client)
    Process.sleep(100)
    refute pid_2 in Serv.acceptors(server_pid)
  end

  describe "suspend / resume" do
    @tag :skip
    test "suspend should stop accepting connections but keep existing ones open" do
      {:ok, server_pid, port} = start_handler(LongEcho, port: 9999)
      {:ok, client} = :gen_tcp.connect(:localhost, port, active: false)

      # Make sure the socket has transitioned ownership to the connection process
      Process.sleep(100)

      :ok = Serv.suspend(server_pid)

      # New connections should fail
      assert :gen_tcp.connect(:localhost, port, [active: false], 100) == {:error, :econnrefused}

      # But existing ones should still be open
      :ok = :gen_tcp.send(client, "HELLO")
      assert :gen_tcp.recv(client, 0) == {:ok, ~c"HELLO"}

      # Now we resume the server
      :ok = Serv.resume(server_pid)

      # New connections should succeed
      {:ok, new_client} = :gen_tcp.connect(:localhost, port, active: false)
      :ok = :gen_tcp.send(new_client, "HELLO")
      assert :gen_tcp.recv(new_client, 0) == {:ok, ~c"HELLO"}
      :gen_tcp.close(new_client)

      # And existing ones should still be open
      :ok = :gen_tcp.send(client, "HELLO")
      assert :gen_tcp.recv(client, 0) == {:ok, ~c"HELLO"}
      :gen_tcp.close(client)
    end
  end

  describe "shutdown" do
    test "it should stop accepting connections but allow existing ones to complete" do
      {:ok, server_pid, port} = start_handler(Echo)
      {:ok, client} = :gen_tcp.connect(:localhost, port, active: false)

      # Make sure the socket has transitioned ownership to the connection process
      Process.sleep(100)
      task = Task.async(fn -> Serv.stop(server_pid) end)
      # Make sure that the stop has had a chance to shutdown the acceptors
      Process.sleep(100)

      assert :gen_tcp.connect(:localhost, port, [active: false], 100) == {:error, :econnrefused}

      :ok = :gen_tcp.send(client, "HELLO")
      assert :gen_tcp.recv(client, 0) == {:ok, ~c"HELLO"}
      :gen_tcp.close(client)

      Task.await(task)

      refute Process.alive?(server_pid)
    end

    @tag :skip
    test "it should give connections a chance to say goodbye" do
      {:ok, server_pid, port} = start_handler(Goodbye)
      {:ok, client} = :gen_tcp.connect(:localhost, port, active: false)

      # Make sure the socket has transitioned ownership to the connection process
      Process.sleep(100)
      task = Task.async(fn -> Serv.stop(server_pid) end)
      # Make sure that the stop has had a chance to shutdown the acceptors
      Process.sleep(100)

      assert :gen_tcp.recv(client, 0) == {:ok, ~c"GOODBYE"}
      :gen_tcp.close(client)

      Task.await(task)

      refute Process.alive?(server_pid)
    end

    @tag :skip
    test "it should still work after a suspend / resume cycle" do
      {:ok, server_pid, port} = start_handler(Goodbye)
      {:ok, client} = :gen_tcp.connect(:localhost, port, active: false)

      # Make sure the socket has transitioned ownership to the connection process
      Process.sleep(100)

      :ok = Serv.suspend(server_pid)
      :ok = Serv.resume(server_pid)

      task = Task.async(fn -> Serv.stop(server_pid) end)
      # Make sure that the stop has had a chance to shutdown the acceptors
      Process.sleep(100)

      assert :gen_tcp.recv(client, 0) == {:ok, ~c"GOODBYE"}
      :gen_tcp.close(client)

      Task.await(task)

      refute Process.alive?(server_pid)
    end

    @tag :skip
    test "it should forcibly shutdown connections after shutdown_timeout" do
      {:ok, server_pid, port} = start_handler(Echo, shutdown_timeout: 500)
      {:ok, client} = :gen_tcp.connect(:localhost, port, active: false)

      # Make sure the socket has transitioned ownership to the connection process
      Process.sleep(100)
      task = Task.async(fn -> Serv.stop(server_pid) end)
      # Make sure that the stop is still waiting on the open client, and the client is still alive
      Process.sleep(100)
      assert Process.alive?(server_pid)
      :gen_tcp.send(client, "HELLO")
      assert :gen_tcp.recv(client, 0) == {:ok, ~c"HELLO"}

      # Make sure that the stop finished by shutdown_timeout
      Process.sleep(500)
      refute Process.alive?(server_pid)

      # Clean up by waiting on the shutdown task
      Task.await(task)
    end
  end

  defp start_handler(handler, opts \\ []) do
    resolved_args = opts |> Keyword.put_new(:port, 0) |> Keyword.put(:handler, handler)
    server_pid = start_supervised!({Serv, resolved_args})
    {:ok, %{port: port}} = Serv.sockname(server_pid)
    {:ok, server_pid, port}
  end
end
