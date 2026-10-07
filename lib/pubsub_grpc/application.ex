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
          port: 443
        ],
        pool: [
          size: 10,
          name: PubsubGrpc.ConnectionPool
        ],
        connection: [
          keepalive: 30_000,
          ping_interval: 25_000
        ]

  A `:production` endpoint without `:ssl` (or with `ssl: []`) uses verified TLS:
  the system CA store, peer verification and hostname checking. To adjust it,
  merge options over those defaults:

      config :pubsub_grpc, :ssl_opts, versions: [:"tlsv1.3"]

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

  The auth token is sent only over TLS connections: a plaintext `:local`
  endpoint (the emulator) never gets one.

  ### Startup errors

  The application refuses to start, with a message describing the fix, when:

    * `config :pubsub_grpc, GrpcConnectionPool` is present but invalid. It is
      never silently replaced by production defaults.
    * an endpoint that is not `type: :local` has no TLS (`:ssl` / `:credentials`),
      because authentication tokens would be sent in plaintext.

  ## Legacy Configuration Support

  The following legacy configuration is still supported when
  `config :pubsub_grpc, GrpcConnectionPool` is absent:

      # config/config.exs
      config :pubsub_grpc, :default_pool_size, 10
      config :pubsub_grpc, :emulator, [
        project_id: "my-project-id",
        host: "localhost",
        port: 8085
      ]

  `:emulator` must be a keyword list; any other value is ignored (with a warning)
  and the production endpoint is used.

  ## Supervising the pool yourself

  Set `config :pubsub_grpc, :start_pool, false` to keep this application from
  starting the default pool, then add `PubsubGrpc` (see `PubsubGrpc.child_spec/1`)
  to your own supervision tree.

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

  alias PubsubGrpc.Config

  @impl true
  def start(_type, _args) do
    env = Application.get_all_env(:pubsub_grpc)
    resolved = Config.resolve(env)
    Config.put(resolved)
    log_config(resolved, env)

    opts = [strategy: :one_for_one, name: PubsubGrpc.Supervisor, max_restarts: 10]
    Supervisor.start_link(children(resolved, env), opts)
  end

  @doc false
  @spec children(Config.resolved(), keyword()) :: [Supervisor.child_spec() | module() | tuple()]
  def children(resolved, env) do
    pool =
      if Keyword.get(env, :start_pool, true) == false,
        do: [],
        else: [{GrpcConnectionPool, resolved.pool_config}]

    [
      # Runs auth token fetches for Auth.Cache; must start before it.
      {Task.Supervisor, name: PubsubGrpc.TaskSupervisor},
      PubsubGrpc.Auth.Cache
      | pool
    ]
  end

  defp log_config(resolved, env) do
    case resolved.source do
      :app_env -> Logger.info("PubsubGrpc: connection pool configured from application env")
      :legacy -> Logger.info("PubsubGrpc: connection pool configured from legacy config")
    end

    emulator = Keyword.get(env, :emulator)

    if resolved.source == :legacy and not is_nil(emulator) and not is_list(emulator) do
      Logger.warning(
        "PubsubGrpc: ignoring `config :pubsub_grpc, :emulator, #{inspect(emulator)}`: " <>
          "it must be a keyword list (host:, port:). Using the production endpoint."
      )
    end

    if resolved.endpoint_type == :local do
      Logger.warning(
        "PubsubGrpc: endpoint type is :local (emulator) — authentication will be skipped. " <>
          "Do not use this configuration in production."
      )
    end
  end
end
