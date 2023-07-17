defmodule Serv.Handler do
  @moduledoc """
  TODO
  """

  @type socket :: :inet.socket()

  @callback handle_connection(socket, state) :: {:continue, state} | {:close, state}
            when state: term

  @callback handle_data(socket, data :: binary, state) :: {:continue, state} | {:close, state}
            when state: term

  defmacro __using__(_opts) do
    quote do
      @behaviour Serv.Handler

      @impl true
      def handle_connection(_socket, state), do: {:continue, state}

      @impl true
      def handle_data(_socket, _data, state), do: {:continue, state}

      defoverridable handle_connection: 2, handle_data: 3
    end
  end
end
