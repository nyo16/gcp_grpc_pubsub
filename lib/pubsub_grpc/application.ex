defmodule PubsubGrpc.Application do
  @moduledoc """
  Application module for PubsubGrpc.

  This module starts the default gRPC connection pool using the GrpcConnectionPool library.
  The pool is configured based on application environment settings and supports both
  production Google Cloud Pub/Sub and emulator environments.

  ## Configuration

  ### Production Configuration (Google Cloud)

      # config/prod.exs
      config :pubsub_grpc, GrpcConnectionPool,
        endpoint: [
          type: :production,
          host: "pubsub.googleapis.com",
          port: 443,
          ssl: []
        ],
        pool: [
          size: 10,
          name: PubsubGrpc.ConnectionPool
        ],
        connection: [
          keepalive: 30_000,
          ping_interval: 25_000
        ]

  ### Emulator Configuration (Development/Testing)

      # config/dev.exs
      config :pubsub_grpc, GrpcConnectionPool,
        endpoint: [
          type: :local,
          host: "localhost",
          port: 8085
        ],
        pool: [
          size: 3,
          name: PubsubGrpc.ConnectionPool
        ],
        connection: [
          ping_interval: nil  # Disable pinging for emulator
        ]

  ## Legacy Configuration Support

  The following legacy configuration is still supported:

      # config/config.exs
      config :pubsub_grpc, :default_pool_size, 10
      config :pubsub_grpc, :emulator, [
        project_id: "my-project-id",
        host: "localhost",
        port: 8085
      ]

  ## Custom Pools

  You can add additional pools to your own application supervision tree:

      # In your application.ex
      defmodule MyApp.Application do
        def start(_type, _args) do
          {:ok, config} = GrpcConnectionPool.Config.local(
            host: "localhost",
            port: 8085,
            pool_name: MyApp.CustomPool
          )

          children = [
            # Your other services...
            {GrpcConnectionPool, config}
          ]

          Supervisor.start_link(children, opts)
        end
      end

  """
  use Application

  @impl true
  def start(_type, _args) do
    config = build_connection_pool_config()

    # Start GrpcConnectionPool.Pool directly since child_spec returns Poolex tuple format
    pool_name = config.pool.name || PubsubGrpc.ConnectionPool

    child_spec = %{
      id: pool_name,
      start: {GrpcConnectionPool.Pool, :start_link, [config, [name: pool_name]]},
      type: :supervisor,
      restart: :permanent,
      shutdown: 5000
    }

    children = [child_spec]

    opts = [strategy: :one_for_one, name: PubsubGrpc.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Private functions

  defp build_connection_pool_config do
    # Try to load from new GrpcConnectionPool configuration first
    case GrpcConnectionPool.Config.from_env(:pubsub_grpc) do
      {:ok, config} -> config
      {:error, _} -> build_legacy_config()
    end
  end

  # Support legacy configuration format
  defp build_legacy_config do
    pool_size = Application.get_env(:pubsub_grpc, :default_pool_size, 5)
    emulator_config = Application.get_env(:pubsub_grpc, :emulator)

    config_opts =
      case emulator_config do
        nil ->
          # Production Google Cloud Pub/Sub
          [
            endpoint: [
              type: :production,
              host: "pubsub.googleapis.com",
              port: 443,
              ssl: []
            ],
            pool: [size: pool_size, name: PubsubGrpc.ConnectionPool]
          ]

        emulator_opts when is_list(emulator_opts) ->
          # Local emulator
          [
            endpoint: [
              type: :local,
              host: emulator_opts[:host] || "localhost",
              port: emulator_opts[:port] || 8085
            ],
            pool: [size: pool_size, name: PubsubGrpc.ConnectionPool],
            # Disable pinging for emulator
            connection: [ping_interval: nil, health_check: true]
          ]

        _ ->
          # Default production
          [
            endpoint: [
              type: :production,
              host: "pubsub.googleapis.com",
              port: 443,
              ssl: []
            ],
            pool: [size: pool_size, name: PubsubGrpc.ConnectionPool]
          ]
      end

    case GrpcConnectionPool.Config.new(config_opts) do
      {:ok, config} ->
        config

      {:error, _reason} ->
        # Fallback to basic production config
        {:ok, config} =
          GrpcConnectionPool.Config.production(
            host: "pubsub.googleapis.com",
            port: 443,
            pool_name: PubsubGrpc.ConnectionPool,
            pool_size: pool_size
          )

        config
    end
  end
end
