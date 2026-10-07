defmodule PubsubGrpc.Client do
  @moduledoc """
  Client module for interacting with Google Cloud Pub/Sub using gRPC connections.

  This module provides a wrapper around `GrpcConnectionPool` that automatically
  uses the default connection pool configured for Pub/Sub.

  For most use cases, use the main `PubsubGrpc` module instead, as it provides
  a higher-level API for common operations.

  ## Examples

      operation = fn channel ->
        request = %Google.Pubsub.V1.GetTopicRequest{topic: "projects/my-project/topics/my-topic"}
        {:ok, auth_opts} = PubsubGrpc.Auth.request_opts(channel)
        Google.Pubsub.V1.Publisher.Stub.get_topic(channel, request, auth_opts)
      end

      {:ok, {:ok, topic}} = PubsubGrpc.Client.execute(operation)

  """

  alias PubsubGrpc.Config

  @typedoc "A gRPC channel checked out from the pool (`%GRPC.Channel{}`)."
  @type channel :: %GRPC.Channel{}

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

  ## Examples

      operation = fn channel ->
        request = %Google.Pubsub.V1.Topic{name: "projects/my-project/topics/test"}
        Google.Pubsub.V1.Publisher.Stub.create_topic(channel, request, [])
      end

      {:ok, {:ok, topic}} = PubsubGrpc.Client.execute(operation)

  """
  @spec execute((channel() -> term()), keyword()) :: {:ok, term()} | {:error, term()}
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

  @doc """
  Execute a function with a connection from the pool.

  Alias for `execute/2`.
  """
  @spec with_connection((channel() -> term()), keyword()) ::
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
