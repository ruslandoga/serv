defmodule Serv.SocketTest do
  use ExUnit.Case

  defmodule Echo do
    use Serv.Handler

    @impl true
    def handle_connection(socket, state) do
      {:ok, data} = :socket.recv(socket, 0)

      with :ok <- :socket.send(socket, data) do
        {:close, state}
      end
    end
  end

  defmodule Sendfile do
    use Serv.Handler

    @impl true
    def handle_connection(socket, state) do
      path = Path.expand("./support/sendfile", __DIR__)
      {:ok, fd} = :file.open(String.to_charlist(path), [:raw, :read, :binary])

      try do
        {:ok, _bytes_sent} = :socket.sendfile(socket, fd, 0, 6)
        {:ok, _bytes_sent} = :socket.sendfile(socket, fd, 1, 3)
        {:close, state}
      after
        :file.close(fd)
      end
    end
  end

  defmodule Closer do
    use Serv.Handler

    @impl true
    def handle_connection(_socket, state) do
      {:close, state}
    end
  end

  defmodule Info do
    use Serv.Handler

    @impl true
    def handle_connection(socket, state) do
      {:ok, peer} = :socket.peername(socket)
      {:ok, local} = :socket.sockname(socket)
      data = inspect([{local.addr, local.port}, {peer.addr, peer.port}])
      with :ok <- :socket.send(socket, data), do: {:close, state}
    end
  end

  describe "common behaviour using :gen_tcp" do
    test "should send and receive" do
      {:ok, port} = start_handler(Echo)
      {:ok, client} = :gen_tcp.connect(~c"localhost", port, active: false)

      assert :gen_tcp.send(client, "HELLO") == :ok
      assert :gen_tcp.recv(client, 0) == {:ok, ~c"HELLO"}
    end

    test "it should send files" do
      {:ok, port} = start_handler(Sendfile)
      {:ok, client} = :gen_tcp.connect(~c"localhost", port, active: false)

      assert :gen_tcp.recv(client, 9) == {:ok, ~c"ABCDEFBCD"}
    end

    test "it should close connections" do
      {:ok, port} = start_handler(Closer)
      {:ok, client} = :gen_tcp.connect(~c"localhost", port, active: false)

      assert :gen_tcp.recv(client, 0) == {:error, :closed}
    end
  end

  describe "behaviour specific to gen_tcp" do
    test "it should provide correct connection info" do
      {:ok, port} = start_handler(Info)
      {:ok, client} = :gen_tcp.connect(~c"localhost", port, active: false)
      on_exit(fn -> :gen_tcp.close(client) end)

      {:ok, resp} = :gen_tcp.recv(client, 0)
      {:ok, local_port} = :inet.port(client)

      expected = [
        {{127, 0, 0, 1}, port},
        {{127, 0, 0, 1}, local_port}
      ]

      assert to_string(resp) == inspect(expected)
    end
  end

  defp start_handler(handler) do
    server_pid = start_supervised!({Serv, port: 0, handler: handler})
    {:ok, %{port: port}} = Serv.sockname(server_pid)
    {:ok, port}
  end
end
