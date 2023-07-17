defmodule Serv.Acceptor do
  @moduledoc false

  require Record
  Record.defrecordp(:timeouts, [:accept, :recv])

  def start_link(parent, listen_socket, timeouts, handler) do
    :proc_lib.spawn_link(__MODULE__, :accept, [parent, listen_socket, timeouts, handler])
  end

  @doc false
  def accept(parent, listen_socket, timeouts, handler) do
    case :socket.accept(listen_socket, timeouts(timeouts, :accept)) do
      {:ok, socket} ->
        GenServer.cast(parent, :accepted)

        case handler.handle_connection(socket, _state = []) do
          {:continue, state} ->
            continue_loop(socket, timeouts, handler, state)

          {:close, _state} ->
            :socket.close(socket)
            exit(:normal)
        end

      {:error, :timeout} ->
        accept(parent, listen_socket, timeouts, handler)

      {:error, :econnaborted} ->
        accept(parent, listen_socket, timeouts, handler)

      {:error, :closed} ->
        :ok

      {:error, _reason} = error ->
        exit(error)
    end
  end

  defp continue_loop(socket, timeouts, handler, state) do
    case handle_data(socket, timeouts, handler, state) do
      {:continue, state} ->
        continue_loop(socket, timeouts, handler, state)

      {:close, _state} ->
        :socket.close(socket)
        exit(:normal)

      {:error, _reason} = error ->
        :socket.close(socket)
        exit(error)
    end
  end

  defp handle_data(socket, timeouts, handler, state) do
    case :socket.recv(socket, 0, timeouts(timeouts, :recv)) do
      {:ok, data} ->
        handler.handle_data(data, socket, state)

      {:error, _reason} ->
        :socket.close(socket)
        exit(:normal)
    end
  end

  def build_timeouts(opts) do
    timeouts(
      accept: opts[:accept] || :timer.seconds(10),
      recv: opts[:recv] || :timer.seconds(60)
    )
  end
end
