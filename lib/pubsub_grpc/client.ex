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
        Google.Pubsub.V1.Publisher.Stub.get_topic(channel, request, [])
      end

      {:ok, {:ok, topic}} = PubsubGrpc.Client.execute(operation)

  """

  @default_pool PubsubGrpc.ConnectionPool

  @doc """
  Execute a gRPC operation using a connection from the pool.

  ## Parameters
  - `operation_fn`: A 1-arity function that receives a gRPC channel and returns a result
  - `opts`: Optional parameters
    - `:pool` - Pool name to use (default: `PubsubGrpc.ConnectionPool`)

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
  @spec execute((GRPC.Channel.t() -> term()), keyword()) :: {:ok, term()} | {:error, term()}
  def execute(operation_fn, opts \\ []) when is_function(operation_fn, 1) do
    pool_name = opts[:pool] || @default_pool

    case GrpcConnectionPool.get_channel(pool_name) do
      {:ok, channel} -> {:ok, operation_fn.(channel)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Execute a function with a connection from the pool.

  Alias for `execute/2`.
  """
  @spec with_connection((GRPC.Channel.t() -> term()), keyword()) ::
          {:ok, term()} | {:error, term()}
  def with_connection(fun, opts \\ []) when is_function(fun, 1) do
    execute(fun, opts)
  end

  @doc """
  Gets the status of the connection pool.

  ## Parameters
  - `opts`: Optional parameters
    - `:pool` - Pool name to check (default: `PubsubGrpc.ConnectionPool`)

  ## Returns
  - Pool status map with worker counts and statistics

  """
  @spec status(keyword()) :: map()
  def status(opts \\ []) do
    pool_name = opts[:pool] || @default_pool
    GrpcConnectionPool.status(pool_name)
  end
end
