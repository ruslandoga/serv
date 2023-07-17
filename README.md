# Serv

Alternative acceptor pool for Thousand Island.

```elixir
defmodule Echo do
  use Serv.Handler

  def handle_data(data, socket, state) do
    with :ok <- :socket.send(socket, data) do
      {:continue, state}
    end
  end
end

Serv.start_link(port: 8000, handler: Echo)
```
