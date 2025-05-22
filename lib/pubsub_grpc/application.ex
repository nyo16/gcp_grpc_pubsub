defmodule PubsubGrpc.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Poolex, worker_module: PubsubGrpc.Connection, workers_count: 5}
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: PubsubGrpc.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
