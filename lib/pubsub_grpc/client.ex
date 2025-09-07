defmodule PubsubGrpc.Client do
  @moduledoc """
  Client module for interacting with Google Cloud Pub/Sub using GRPC connections.

  This module provides a convenient wrapper around `PubsubGrpc.ConnectionPool` that
  automatically uses the default connection pool.

  For most use cases, you should use the main `PubsubGrpc` module instead of this one,
  as it provides a higher-level API for common operations.

  ## When to use this module

  - When you need to execute custom GRPC operations not covered by the main API
  - When you want to work directly with GRPC channels for advanced use cases
  - When building higher-level abstractions on top of the connection pool

  ## Examples

      # Execute a custom operation
      operation = fn channel ->
        request = %Google.Pubsub.V1.GetTopicRequest{topic: "projects/my-project/topics/my-topic"}
        Google.Pubsub.V1.Publisher.Stub.get_topic(channel, request)
      end
      
      {:ok, topic} = PubsubGrpc.Client.execute(operation)

      # Execute on a custom pool
      {:ok, topic} = PubsubGrpc.Client.execute(operation, pool: MyApp.CustomPool)

  """

  alias PubsubGrpc.ConnectionPool

  @doc """
  Execute a GRPC operation using a connection from the default pool.

  This is a convenience function that uses the default connection pool.
  For custom pools, specify the `:pool` option.

  ## Parameters
  - `operation_fn`: Function that takes `(channel)` and returns a result
  - `opts`: Optional parameters
    - `:pool` - Pool name to use (default: PubsubGrpc.ConnectionPool)
    - `:checkout_timeout` - Timeout for checking out connections

  ## Returns
  - Result from the operation function
  - `{:error, reason}` - Error during execution or connection checkout

  ## Examples

      operation = fn channel ->
        request = %Google.Pubsub.V1.Topic{name: "projects/my-project/topics/test"}
        Google.Pubsub.V1.Publisher.Stub.create_topic(channel, request)
      end

      {:ok, topic} = PubsubGrpc.Client.execute(operation)
      {:ok, topic} = PubsubGrpc.Client.execute(operation, pool: MyApp.CustomPool)

  """
  @spec execute(function(), keyword()) :: any()
  def execute(operation_fn, opts \\ [])

  # Handle 1-arity functions (new API)
  def execute(operation_fn, opts) when is_function(operation_fn, 1) do
    ConnectionPool.execute(operation_fn, opts)
  end

  # Handle 2-arity functions (backward compatibility)
  def execute(operation_fn, params) when is_function(operation_fn, 2) do
    # Wrap the 2-arity function to be 1-arity
    wrapped_fn = fn channel -> operation_fn.(channel, params) end
    
    opts = if is_list(params), do: [], else: []
    ConnectionPool.execute(wrapped_fn, opts)
  end

  @doc """
  Execute a function within a connection from the default pool.
  
  This is for backward compatibility with the old API.
  """
  @spec with_connection(function()) :: any()
  def with_connection(fun) when is_function(fun, 1) do
    execute(fun)
  end

  @doc """
  Gets the status of the default connection pool.

  ## Parameters
  - `opts`: Optional parameters
    - `:pool` - Pool name to check (default: PubsubGrpc.ConnectionPool)

  ## Returns
  - Pool status map with worker counts and statistics

  ## Examples

      status = PubsubGrpc.Client.status()
      status = PubsubGrpc.Client.status(pool: MyApp.CustomPool)

  """
  @spec status(keyword()) :: map()
  def status(opts \\ []) do
    pool_name = opts[:pool] || PubsubGrpc.ConnectionPool
    ConnectionPool.status(pool_name)
  end
end
