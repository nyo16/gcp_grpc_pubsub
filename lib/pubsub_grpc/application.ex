defmodule PubsubGrpc.Application do
  @moduledoc """
  Application module for PubsubGrpc.

  This module starts the default connection pool using Poolex when the application starts.
  The pool is configured based on application environment settings and supports both
  production and emulator environments.

  ## Configuration

  ### Basic Configuration

      # config/config.exs
      config :pubsub_grpc,
        endpoint: [type: :production],
        pool: [size: 10],
        connection: [ping_interval: 30_000]

  ### Emulator Configuration

      # config/dev.exs  
      config :pubsub_grpc,
        endpoint: [
          type: :emulator,
          project_id: "my-project-id",
          host: "localhost", 
          port: 8085
        ],
        pool: [size: 3]

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
          {:ok, config} = PubsubGrpc.PoolConfig.emulator(project_id: "test", pool_name: MyApp.CustomPool)
          
          children = [
            # Your other services...
            {PubsubGrpc.ConnectionPool, config}
          ]
          
          Supervisor.start_link(children, opts)
        end
      end

  """
  use Application

  alias PubsubGrpc.PoolConfig

  @impl true
  def start(_type, _args) do
    config = build_default_config()

    # Start Poolex directly instead of using ConnectionPool wrapper
    poolex_spec = {
      Poolex,
      worker_module: PubsubGrpc.ConnectionWorker,
      worker_args: [config],
      workers_count: config.pool.size,
      name: config.pool.name || PubsubGrpc.ConnectionPool
    }

    children = [poolex_spec]

    opts = [strategy: :one_for_one, name: PubsubGrpc.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Private functions

  defp build_default_config do
    # Check for new configuration format first
    case Application.get_all_env(:pubsub_grpc) do
      config when is_list(config) ->
        case PoolConfig.from_env(:pubsub_grpc) do
          {:ok, config} -> config
          {:error, _} -> build_legacy_config()
        end

      _ ->
        build_legacy_config()
    end
  end

  # Support legacy configuration format
  defp build_legacy_config do
    pool_size = Application.get_env(:pubsub_grpc, :default_pool_size, 5)
    emulator_config = Application.get_env(:pubsub_grpc, :emulator)

    config_opts =
      case emulator_config do
        nil ->
          [
            endpoint: [type: :production],
            pool: [size: pool_size, name: PubsubGrpc.ConnectionPool]
          ]

        emulator_opts when is_list(emulator_opts) ->
          [
            endpoint:
              [
                type: :emulator,
                host: emulator_opts[:host] || "localhost",
                port: emulator_opts[:port] || 8085,
                project_id: emulator_opts[:project_id]
              ] |> Enum.reject(fn {_, v} -> is_nil(v) end),
            pool: [size: pool_size, name: PubsubGrpc.ConnectionPool]
          ]

        _ ->
          [
            endpoint: [type: :production],
            pool: [size: pool_size, name: PubsubGrpc.ConnectionPool]
          ]
      end

    case PoolConfig.new(config_opts) do
      {:ok, config} -> config
      {:error, _} -> 
        # Fallback to basic production config
        {:ok, config} = PoolConfig.production(pool_size: pool_size, pool_name: PubsubGrpc.ConnectionPool)
        config
    end
  end
end
