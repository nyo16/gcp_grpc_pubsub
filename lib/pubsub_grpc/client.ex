defmodule PubsubGrpc.Client do
  @moduledoc false

  # Internal: checks out a channel from the pool and runs a callback on it, returning
  # `{:ok, callback_result}` without normalizing errors or attaching auth. The public
  # entry point is `PubsubGrpc.execute/2`, which normalizes errors to
  # `PubsubGrpc.Error`; callbacks get auth options from `PubsubGrpc.Auth.request_opts/1`.

  alias PubsubGrpc.Config

  @doc """
  Execute a gRPC operation using a connection from the pool.

  ## Parameters
  - `operation_fn`: A 1-arity function that receives a gRPC channel and returns a result
  - `opts`: Optional parameters
    - `:pool` - Pool name to use (default: the configured pool, `PubsubGrpc.ConnectionPool`
      unless `config :pubsub_grpc, GrpcConnectionPool` sets `pool: [name: ...]`)
    - `:timeout` - Bounds the wait for a connection (see below; default: the
      `:default_timeout` app env, 30s)

  If no connection is ready (`:not_connected`, e.g. right after startup or while
  reconnecting), waits up to `min(timeout, 2_000)` ms for one and retries the
  checkout once.

  ## Returns
  - `{:ok, result}` - Result from the operation function
  - `{:error, reason}` - Error during connection checkout

  Internal: use `PubsubGrpc.execute/2`, which normalizes errors to `PubsubGrpc.Error`.
  """
  @spec execute((PubsubGrpc.channel() -> term()), keyword()) :: {:ok, term()} | {:error, term()}
  def execute(operation_fn, opts \\ []) when is_function(operation_fn, 1) do
    pool_name = opts[:pool] || Config.pool_name()

    case checkout(pool_name, opts) do
      {:ok, channel} -> {:ok, operation_fn.(channel)}
      {:error, reason} -> {:error, reason}
    end
  end

  @max_ready_wait 2_000

  defp checkout(pool_name, opts) do
    with {:error, :not_connected} <- GrpcConnectionPool.get_channel(pool_name),
         :ok <- await_ready(pool_name, opts) do
      GrpcConnectionPool.get_channel(pool_name)
    end
  end

  defp await_ready(pool_name, opts) do
    timeout = PubsubGrpc.Request.timeout(opts)

    case GrpcConnectionPool.await_ready(pool_name, max(min(timeout, @max_ready_wait), 1)) do
      :ok -> :ok
      {:error, :timeout} -> {:error, :not_connected}
    end
  rescue
    # await_ready/2 raises if the pool does not exist (no ETS table): nothing to wait for.
    ArgumentError -> {:error, :not_connected}
  end

  # Deprecated rather than only hidden: `@moduledoc false` already hides it from the docs,
  # but callers from when Client was public need a compile-time pointer to the migration.
  @deprecated "Use PubsubGrpc.execute/2"
  @spec with_connection((PubsubGrpc.channel() -> term()), keyword()) ::
          {:ok, term()} | {:error, term()}
  def with_connection(fun, opts \\ []) when is_function(fun, 1) do
    execute(fun, opts)
  end

  @doc """
  Gets the status of the connection pool.

  ## Parameters
  - `opts`: Optional parameters
    - `:pool` - Pool name to check (default: the configured pool)

  ## Returns
  - Pool status map with worker counts and statistics

  """
  @spec status(keyword()) :: map()
  def status(opts \\ []) do
    pool_name = opts[:pool] || Config.pool_name()
    GrpcConnectionPool.status(pool_name)
  end
end
