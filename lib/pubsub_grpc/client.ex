defmodule PubsubGrpc.Client do
  @moduledoc """
  Client module for interacting with Google Cloud Pub/Sub using GRPC connections.

  This module provides a convenient wrapper around `PubsubGrpc.Connection` that
  automatically uses the default connection pool (`PubsubGrpc.ConnectionPool`).

  For most use cases, you should use the main `PubsubGrpc` module instead of this one,
  as it provides a higher-level API for common operations.

  ## When to use this module

  - When you need to execute custom GRPC operations not covered by the main API
  - When you want to work directly with GRPC channels for advanced use cases
  - When building higher-level abstractions on top of the connection pool

  ## Examples

      # Execute a custom operation
      operation = fn channel, _params ->
        request = %Google.Pubsub.V1.GetTopicRequest{topic: "projects/my-project/topics/my-topic"}
        Google.Pubsub.V1.Publisher.Stub.get_topic(channel, request)
      end
      
      {:ok, topic} = PubsubGrpc.Client.execute(operation)

      # Work directly with a connection
      result = PubsubGrpc.Client.with_connection(fn channel ->
        # Perform multiple operations with the same channel
        {:ok, topics} = Google.Pubsub.V1.Publisher.Stub.list_topics(channel, request1)
        {:ok, subs} = Google.Pubsub.V1.Subscriber.Stub.list_subscriptions(channel, request2)
        {topics, subs}
      end)

  """

  @doc """
  Execute a GRPC operation using a connection from the default pool.

  This is a convenience function that uses the default `PubsubGrpc.ConnectionPool`.
  For custom pools, use `PubsubGrpc.Connection.execute/3` directly.

  ## Parameters
  - `operation_fn`: Function that takes `(channel, params)` and returns a result
  - `params`: Optional parameters to pass to the operation function (default: [])

  ## Returns
  - Result from the operation function
  - `{:error, reason}` - Error during execution or connection checkout

  ## Examples

      operation = fn channel, _params ->
        request = %Google.Pubsub.V1.Topic{name: "projects/my-project/topics/test"}
        Google.Pubsub.V1.Publisher.Stub.create_topic(channel, request)
      end

      {:ok, topic} = PubsubGrpc.Client.execute(operation)

  """
  def execute(operation_fn, params \\ []) do
    PubsubGrpc.Connection.execute(PubsubGrpc.ConnectionPool, operation_fn, params)
  end

  @doc """
  Execute a function within a connection from the default pool.

  This is a convenience function that uses the default `PubsubGrpc.ConnectionPool`.
  For custom pools, use `PubsubGrpc.Connection.with_connection/2` directly.

  ## Parameters  
  - `fun`: Function that takes `(channel)` and returns a result

  ## Returns
  - Result from the function
  - May raise if connection checkout fails

  ## Examples

      result = PubsubGrpc.Client.with_connection(fn channel ->
        request = %Google.Pubsub.V1.ListTopicsRequest{project: "projects/my-project"}
        Google.Pubsub.V1.Publisher.Stub.list_topics(channel, request)
      end)

  """
  def with_connection(fun) when is_function(fun, 1) do
    PubsubGrpc.Connection.with_connection(PubsubGrpc.ConnectionPool, fun)
  end
end
