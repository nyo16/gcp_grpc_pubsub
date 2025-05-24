defmodule PubsubGrpc.Application do
  use Application

  @impl true
  def start(_type, _args) do
    workers_count = Application.get_env(:pubsub_grpc, :connection_pool)[:workers_count] || 5

    children = [
      {Poolex, worker_module: PubsubGrpc.Connection, workers_count: workers_count}
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: PubsubGrpc.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
