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

  require Logger

  @impl true
  def start(_type, _args) do
    warn_if_emulator_mode()
    config = build_connection_pool_config()

    children = [
      PubsubGrpc.Auth.Cache,
      {GrpcConnectionPool, config}
    ]

    opts = [strategy: :one_for_one, name: PubsubGrpc.Supervisor, max_restarts: 10]
    Supervisor.start_link(children, opts)
  end

  defp warn_if_emulator_mode do
    if Application.get_env(:pubsub_grpc, :emulator) do
      Logger.warning(
        "PubsubGrpc: emulator mode is active — authentication will be skipped. " <>
          "Remove `config :pubsub_grpc, :emulator, _` for production."
      )
    end
  end

  # Private functions

  defp build_connection_pool_config do
    # Try to load from new GrpcConnectionPool configuration first
    case GrpcConnectionPool.Config.from_env(:pubsub_grpc) do
      {:ok, config} ->
        Logger.info("PubsubGrpc: connection pool configured from application env")
        config

      {:error, reason} ->
        Logger.debug(
          "PubsubGrpc: no pool config in env (#{inspect(reason)}), trying legacy config"
        )

        build_legacy_config()
    end
  end

  # Support legacy configuration format
  defp build_legacy_config do
    pool_size = Application.get_env(:pubsub_grpc, :default_pool_size, 5)
    config_opts = legacy_config_opts(Application.get_env(:pubsub_grpc, :emulator), pool_size)

    case GrpcConnectionPool.Config.new(config_opts) do
      {:ok, config} ->
        Logger.info("PubsubGrpc: connection pool configured from legacy config")
        config

      {:error, reason} ->
        Logger.error("PubsubGrpc: legacy config failed: #{inspect(reason)}")
        production_default_config!(pool_size, reason)
    end
  end

  defp legacy_config_opts(emulator_opts, pool_size) when is_list(emulator_opts) do
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
  end

  defp legacy_config_opts(_emulator_opts, pool_size) do
    [
      endpoint: [
        type: :production,
        host: "pubsub.googleapis.com",
        port: 443,
        ssl: production_ssl_opts()
      ],
      pool: [size: pool_size, name: PubsubGrpc.ConnectionPool]
    ]
  end

  defp production_default_config!(pool_size, reason) do
    case GrpcConnectionPool.Config.production(
           host: "pubsub.googleapis.com",
           port: 443,
           pool_name: PubsubGrpc.ConnectionPool,
           pool_size: pool_size
         ) do
      {:ok, config} ->
        Logger.warning("PubsubGrpc: using production defaults after legacy config failure")
        config

      {:error, fallback_reason} ->
        raise "PubsubGrpc: unable to build connection pool config " <>
                "(legacy: #{inspect(reason)}, production default: #{inspect(fallback_reason)})"
    end
  end

  # Strict TLS for the production endpoint: verify the server certificate against
  # the OS trust store. Override via `config :pubsub_grpc, :ssl_opts, [...]`.
  defp production_ssl_opts do
    Application.get_env(
      :pubsub_grpc,
      :ssl_opts,
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get()
    )
  end
end
