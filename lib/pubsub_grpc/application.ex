defmodule PubsubGrpc.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {PubsubGrpc.Connection, [
        name: PubsubGrpc.ConnectionPool,
        pool_size: 5
      ]}
    ]

    opts = [strategy: :one_for_one, name: PubsubGrpc.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
