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

  ## Default configuration

  When `config :pubsub_grpc, GrpcConnectionPool` is absent, the pool connects to
  production Pub/Sub (`pubsub.googleapis.com:443`, verified TLS), or to the
  emulator when the `:emulator` shorthand is set:

      # config/dev.exs
      config :pubsub_grpc, :emulator, host: "localhost", port: 8085
      # Pool size for either endpoint (default: 5)
      config :pubsub_grpc, :default_pool_size, 10

  `:emulator` must be a keyword list; any other value is ignored (with a warning)
  and the production endpoint is used.

  ## Supervision

  The supervisor allows 10 restarts in 5 seconds. If a child (the pool or the
  auth token cache) crashes more often than that, the `:pubsub_grpc` application
  stops. What happens next depends on how it was started: in a `mix release`,
  applications are started `:permanent` by default, so the whole node shuts down
  (and is restarted by its supervisor, e.g. systemd or Kubernetes). Started as a
  `:temporary` application (`mix run`, `iex -S mix`, tests), only `:pubsub_grpc`
  stops; calls then return `:connection_error` (no pool) or an auth error (no
  token cache) until it is started again.

  ## Supervising the pool yourself

  Set `config :pubsub_grpc, :start_pool, false` to keep this application from
  starting the default pool, then add `PubsubGrpc` (see `PubsubGrpc.child_spec/1`)
  to your own supervision tree.

  ## Log redaction

  When grpc's connection process exits during a call, grpc logs the exit
  reason, which contains the request headers, including the bearer token. The
  application installs a `:logger` primary filter that rewrites
  `Bearer <token>` to `Bearer [REDACTED]` in log events emitted by
  `GRPC.Telemetry` only; other events are left untouched. To opt out (e.g. if
  your app already redacts its logs):

      config :pubsub_grpc, :redact_grpc_logs, false

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

  alias PubsubGrpc.{Config, LogRedactor}

  @impl true
  def start(_type, _args) do
    env = Application.get_all_env(:pubsub_grpc)
    resolved = Config.resolve(env)
    Config.put(resolved)
    log_config(resolved, env)

    if Keyword.get(env, :redact_grpc_logs, true) != false, do: LogRedactor.install()

    opts = [
      strategy: :one_for_one,
      name: PubsubGrpc.Supervisor,
      max_restarts: 10,
      max_seconds: 5
    ]

    Supervisor.start_link(children(resolved), opts)
  end

  @impl true
  def stop(_state), do: LogRedactor.uninstall()

  @doc false
  @spec children(Config.resolved()) :: [Supervisor.child_spec() | module() | tuple()]
  def children(resolved) do
    pool = if resolved.start_pool, do: [{GrpcConnectionPool, resolved.pool_config}], else: []

    [
      # Runs auth token fetches for Auth.Cache; must start before it.
      {Task.Supervisor, name: PubsubGrpc.TaskSupervisor},
      PubsubGrpc.Auth.Cache
      | pool
    ]
  end

  # Public only so the startup log lines documented in the moduledoc can be tested.
  @doc false
  @spec log_config(Config.resolved(), keyword()) :: :ok
  def log_config(resolved, env) do
    case resolved.source do
      :app_env -> Logger.info("PubsubGrpc: connection pool configured from application env")
      :default -> Logger.info("PubsubGrpc: connection pool configured from defaults")
    end

    emulator = Keyword.get(env, :emulator)

    if resolved.source == :default and not is_nil(emulator) and not is_list(emulator) do
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

    :ok
  end
end
