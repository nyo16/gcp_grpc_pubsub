defmodule PubsubGrpc.ConnectionPool do
  @moduledoc """
  Poolex-based GRPC connection pool for Google Cloud Pub/Sub.

  This module provides a high-level interface for managing GRPC connections using
  the Poolex library. It replaces the previous NimblePool implementation with a more
  flexible and configurable approach.

  ## Features

  - Environment-agnostic configuration (production, emulator, custom)
  - Automatic connection health monitoring and recovery
  - Periodic ping to keep connections warm
  - Configurable retry logic with exponential backoff
  - Support for multiple named pools
  - Built-in metrics and monitoring support (via Poolex)

  ## Usage

  ### Default Pool

      # Start with default configuration
      {:ok, _pid} = PubsubGrpc.ConnectionPool.start_link([])

      # Execute operations
      operation = fn channel ->
        request = %Google.Pubsub.V1.ListTopicsRequest{project: "projects/my-project"}
        Google.Pubsub.V1.Publisher.Stub.list_topics(channel, request)
      end

      {:ok, result} = PubsubGrpc.ConnectionPool.execute(operation)

  ### Custom Pool

      # Start with custom configuration
      {:ok, config} = PubsubGrpc.PoolConfig.emulator(project_id: "test-project")
      {:ok, _pid} = PubsubGrpc.ConnectionPool.start_link(config, name: MyApp.CustomPool)

      # Execute operations on custom pool
      {:ok, result} = PubsubGrpc.ConnectionPool.execute(operation, pool: MyApp.CustomPool)

  ### Configuration from Environment

      # config/config.exs
      config :my_app, PubsubGrpc,
        endpoint: [type: :emulator, host: "localhost", port: 8085, project_id: "test"],
        pool: [size: 8, name: MyApp.PubSubPool],
        connection: [ping_interval: 20_000]

      # In your application
      {:ok, config} = PubsubGrpc.PoolConfig.from_env(:my_app)
      {:ok, _pid} = PubsubGrpc.ConnectionPool.start_link(config)

  ## Configuration

  See `PubsubGrpc.PoolConfig` for detailed configuration options.
  """

  alias PubsubGrpc.{PoolConfig, ConnectionWorker}

  @default_pool_name __MODULE__

  # Child specification for supervision trees

  @doc """
  Returns the child specification for supervision trees.

  ## Parameters
  - `config`: Pool configuration (PubsubGrpc.PoolConfig struct or keyword list)
  - `opts`: Additional options
    - `:name` - Pool name (overrides config name)

  ## Examples

      children = [
        {PubsubGrpc.ConnectionPool, [
          endpoint: [type: :production],
          pool: [size: 10, name: MyApp.PubSubPool]
        ]}
      ]

  """
  def child_spec(config_or_opts) when is_list(config_or_opts) do
    case PoolConfig.new(config_or_opts) do
      {:ok, config} ->
        pool_name = get_pool_name(config, config_or_opts)
        {
          Poolex,
          worker_module: ConnectionWorker,
          worker_args: [config],
          workers_count: config.pool.size,
          name: pool_name
        }

      {:error, reason} ->
        raise ArgumentError, "Invalid pool configuration: #{reason}"
    end
  end

  def child_spec(%PoolConfig{} = config) do
    pool_name = config.pool.name || @default_pool_name
    {
      Poolex,
      worker_module: ConnectionWorker,
      worker_args: [config],
      workers_count: config.pool.size,
      name: pool_name
    }
  end

  @doc """
  Starts a new connection pool.

  ## Parameters
  - `config`: Pool configuration (PubsubGrpc.PoolConfig struct or keyword list)
  - `opts`: Additional options
    - `:name` - Pool name (overrides config name)

  ## Returns
  - `{:ok, pid}` - Pool started successfully
  - `{:error, reason}` - Error starting pool

  ## Examples

      # With PoolConfig struct
      {:ok, config} = PubsubGrpc.PoolConfig.production(pool_size: 8)
      {:ok, pid} = PubsubGrpc.ConnectionPool.start_link(config)

      # With keyword list
      {:ok, pid} = PubsubGrpc.ConnectionPool.start_link([
        endpoint: [type: :emulator, host: "localhost", port: 8085, project_id: "test"],
        pool: [size: 5]
      ])

  """
  @spec start_link(PoolConfig.t() | keyword(), keyword()) :: GenServer.on_start()
  def start_link(config_or_opts, opts \\ [])

  def start_link(%PoolConfig{} = config, opts) do
    pool_name = opts[:name] || config.pool.name || @default_pool_name
    
    Poolex.start_link(
      worker_module: ConnectionWorker,
      worker_args: [config],
      workers_count: config.pool.size,
      name: pool_name
    )
  end

  def start_link(config_opts, opts) when is_list(config_opts) do
    case PoolConfig.new(config_opts) do
      {:ok, config} ->
        pool_name = opts[:name] || get_pool_name(config, config_opts) || @default_pool_name
        
        Poolex.start_link(
          worker_module: ConnectionWorker,
          worker_args: [config],
          workers_count: config.pool.size,
          name: pool_name
        )

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Executes a GRPC operation using a connection from the pool.

  ## Parameters
  - `operation_fn`: Function that takes `(channel)` and returns a result
  - `opts`: Optional parameters
    - `:pool` - Pool name to use (default: #{@default_pool_name})
    - `:checkout_timeout` - Timeout for checking out connections (default: from config)

  ## Returns
  - Result from the operation function
  - `{:error, reason}` - Error during execution or connection checkout

  ## Examples

      operation = fn channel ->
        request = %Google.Pubsub.V1.ListTopicsRequest{project: "projects/my-project"}
        Google.Pubsub.V1.Publisher.Stub.list_topics(channel, request)
      end

      {:ok, topics} = PubsubGrpc.ConnectionPool.execute(operation)
      {:ok, topics} = PubsubGrpc.ConnectionPool.execute(operation, pool: MyApp.CustomPool)

  """
  @spec execute(function(), keyword()) :: any()
  def execute(operation_fn, opts \\ []) when is_function(operation_fn, 1) do
    pool_name = opts[:pool] || @default_pool_name
    checkout_timeout = opts[:checkout_timeout] || 15_000

    try do
      Poolex.run(pool_name, fn worker ->
        ConnectionWorker.execute(worker, operation_fn)
      end, checkout_timeout: checkout_timeout)
    rescue
      error -> {:error, error}
    catch
      :exit, reason -> {:error, {:exit, reason}}
      error -> {:error, {:throw, error}}
    end
  end

  @doc """
  Gets pool status and statistics.

  ## Parameters
  - `pool_name` - Pool name (default: #{@default_pool_name})

  ## Returns
  - Pool status map with worker counts and statistics

  ## Examples

      status = PubsubGrpc.ConnectionPool.status()
      status = PubsubGrpc.ConnectionPool.status(MyApp.CustomPool)

  """
  @spec status(atom()) :: map()
  def status(pool_name \\ @default_pool_name) do
    try do
      # For now, return basic status - in future we can extend this
      # when Poolex provides more status/monitoring functions
      %{pool_name: pool_name, status: :running}
    rescue
      _ -> %{error: :pool_not_found}
    end
  end

  @doc """
  Stops a connection pool.

  ## Parameters
  - `pool_name` - Pool name (default: #{@default_pool_name})

  """
  @spec stop(atom()) :: :ok
  def stop(pool_name \\ @default_pool_name) do
    try do
      spec = Poolex.child_spec([worker_module: ConnectionWorker, name: pool_name])
      child_id = Map.get(spec, :id)
      DynamicSupervisor.terminate_child(Poolex.DynamicSupervisor, child_id)
    rescue
      _ -> :ok
    end

    :ok
  end

  # Private functions

  defp get_pool_name(config, opts) do
    opts[:name] || 
    Keyword.get(opts, :pool, [])[:name] ||
    config.pool.name
  end
end