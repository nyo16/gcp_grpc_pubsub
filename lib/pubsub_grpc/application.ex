defmodule PubsubGrpc.Application do
  @moduledoc """
  Application module for PubsubGrpc.

  This module starts the default connection pool (`PubsubGrpc.ConnectionPool`) with 5 connections
  when the application starts. The connection pool is supervised under `PubsubGrpc.Supervisor`
  with a `:one_for_one` strategy.

  ## Configuration

  The default pool can be configured via application environment:

      # config/config.exs
      config :pubsub_grpc, :default_pool_size, 10

  For emulator configuration:

      # config/dev.exs  
      config :pubsub_grpc, :emulator,
        project_id: "my-project-id",
        host: "localhost", 
        port: 8085

  ## Custom Pools

  You can add additional pools to your own application supervision tree:

      # In your application.ex
      defmodule MyApp.Application do
        def start(_type, _args) do
          children = [
            # Your other services...
            {PubsubGrpc.Connection, [name: MyApp.CustomPool, pool_size: 8]}
          ]
          
          Supervisor.start_link(children, opts)
        end
      end

  """
  use Application

  @impl true
  def start(_type, _args) do
    pool_size = Application.get_env(:pubsub_grpc, :default_pool_size, 5)

    children = [
      {PubsubGrpc.Connection,
       [
         name: PubsubGrpc.ConnectionPool,
         pool_size: pool_size
       ]}
    ]

    opts = [strategy: :one_for_one, name: PubsubGrpc.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
