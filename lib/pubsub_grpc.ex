defmodule PubsubGrpc do
  @moduledoc """
  Main entry point for Google Cloud Pub/Sub gRPC operations with connection pooling.

  This module provides a convenient API for common Pub/Sub operations like creating topics,
  publishing messages, pulling messages, and managing subscriptions using a connection pool
  powered by NimblePool.

  ## Configuration

  ### Production (Google Cloud)
      # Will connect to pubsub.googleapis.com:443
      # Make sure to set up authentication (service account, gcloud, etc.)

  ### Development/Test (Local Emulator)
      # config/dev.exs
      config :pubsub_grpc, :emulator,
        project_id: "my-project-id",
        host: "localhost",
        port: 8085

  ## Examples

      # Create a topic
      {:ok, topic} = PubsubGrpc.create_topic("my-project", "my-topic")

      # Publish messages
      messages = [%{data: "Hello", attributes: %{"source" => "app"}}]
      {:ok, response} = PubsubGrpc.publish("my-project", "my-topic", messages)

      # Create subscription
      {:ok, subscription} = PubsubGrpc.create_subscription("my-project", "my-topic", "my-sub")

      # Pull messages
      {:ok, messages} = PubsubGrpc.pull("my-project", "my-sub", 10)

      # Acknowledge messages
      ack_ids = Enum.map(messages, & &1.ack_id)
      :ok = PubsubGrpc.acknowledge("my-project", "my-sub", ack_ids)

  """

  alias PubsubGrpc.Client

  @doc """
  Creates a new Pub/Sub topic.

  ## Parameters
  - `project_id`: The Google Cloud project ID
  - `topic_id`: The topic identifier (without the full path)

  ## Returns
  - `{:ok, topic}` - Successfully created topic
  - `{:error, reason}` - Error creating topic

  ## Examples

      {:ok, topic} = PubsubGrpc.create_topic("my-project", "events")
      {:error, %GRPC.RPCError{}} = PubsubGrpc.create_topic("my-project", "existing-topic")

  """
  def create_topic(project_id, topic_id) do
    topic_path = topic_path(project_id, topic_id)
    
    operation = fn channel, _params ->
      request = %Google.Pubsub.V1.Topic{name: topic_path}
      Google.Pubsub.V1.Publisher.Stub.create_topic(channel, request)
    end

    Client.execute(operation)
  end

  @doc """
  Deletes a Pub/Sub topic.

  ## Parameters
  - `project_id`: The Google Cloud project ID
  - `topic_id`: The topic identifier

  ## Returns
  - `:ok` - Successfully deleted topic
  - `{:error, reason}` - Error deleting topic

  """
  def delete_topic(project_id, topic_id) do
    topic_path = topic_path(project_id, topic_id)
    
    operation = fn channel, _params ->
      request = %Google.Pubsub.V1.DeleteTopicRequest{topic: topic_path}
      Google.Pubsub.V1.Publisher.Stub.delete_topic(channel, request)
    end

    case Client.execute(operation) do
      {:ok, %Google.Protobuf.Empty{}} -> :ok
      error -> error
    end
  end

  @doc """
  Lists topics in a project.

  ## Parameters
  - `project_id`: The Google Cloud project ID
  - `opts`: Optional parameters
    - `:page_size`: Maximum number of topics to return
    - `:page_token`: Token for pagination

  ## Returns
  - `{:ok, %{topics: topics, next_page_token: token}}` - List of topics
  - `{:error, reason}` - Error listing topics

  """
  def list_topics(project_id, opts \\ []) do
    project_path = "projects/#{project_id}"
    
    operation = fn channel, _params ->
      request = %Google.Pubsub.V1.ListTopicsRequest{
        project: project_path,
        page_size: Keyword.get(opts, :page_size, 0),
        page_token: Keyword.get(opts, :page_token, "")
      }
      Google.Pubsub.V1.Publisher.Stub.list_topics(channel, request)
    end

    case Client.execute(operation) do
      {:ok, response} -> 
        {:ok, %{topics: response.topics, next_page_token: response.next_page_token}}
      error -> error
    end
  end

  @doc """
  Publishes messages to a topic.

  ## Parameters
  - `project_id`: The Google Cloud project ID
  - `topic_id`: The topic identifier
  - `messages`: List of message maps with `:data` and optional `:attributes`

  ## Message Format
      %{data: "message content", attributes: %{"key" => "value"}}

  ## Returns
  - `{:ok, %{message_ids: [message_ids]}}` - Successfully published messages
  - `{:error, reason}` - Error publishing messages

  ## Examples

      messages = [
        %{data: "Hello World", attributes: %{"source" => "app"}},
        %{data: "Another message"}
      ]
      {:ok, response} = PubsubGrpc.publish("my-project", "my-topic", messages)

  """
  def publish(project_id, topic_id, messages) when is_list(messages) do
    topic_path = topic_path(project_id, topic_id)
    
    operation = fn channel, _params ->
      pubsub_messages = Enum.map(messages, fn msg ->
        %Google.Pubsub.V1.PubsubMessage{
          data: Map.get(msg, :data, ""),
          attributes: Map.get(msg, :attributes, %{})
        }
      end)

      request = %Google.Pubsub.V1.PublishRequest{
        topic: topic_path,
        messages: pubsub_messages
      }

      Google.Pubsub.V1.Publisher.Stub.publish(channel, request)
    end

    case Client.execute(operation) do
      {:ok, response} -> {:ok, %{message_ids: response.message_ids}}
      error -> error
    end
  end

  @doc """
  Convenience function to publish a single message.

  ## Parameters
  - `project_id`: The Google Cloud project ID  
  - `topic_id`: The topic identifier
  - `data`: Message data (string)
  - `attributes`: Optional message attributes (map)

  ## Returns
  - `{:ok, %{message_ids: [message_id]}}` - Successfully published message
  - `{:error, reason}` - Error publishing message

  ## Examples

      {:ok, response} = PubsubGrpc.publish_message("my-project", "my-topic", "Hello!")
      {:ok, response} = PubsubGrpc.publish_message("my-project", "my-topic", "Hello!", %{"source" => "app"})

  """
  def publish_message(project_id, topic_id, data, attributes \\ %{}) do
    message = %{data: data, attributes: attributes}
    publish(project_id, topic_id, [message])
  end

  @doc """
  Creates a subscription to a topic.

  ## Parameters
  - `project_id`: The Google Cloud project ID
  - `topic_id`: The topic identifier
  - `subscription_id`: The subscription identifier
  - `opts`: Optional parameters
    - `:ack_deadline_seconds`: Message acknowledgment deadline (default: 60)

  ## Returns
  - `{:ok, subscription}` - Successfully created subscription
  - `{:error, reason}` - Error creating subscription

  ## Examples

      {:ok, sub} = PubsubGrpc.create_subscription("my-project", "my-topic", "my-sub")
      {:ok, sub} = PubsubGrpc.create_subscription("my-project", "my-topic", "my-sub", ack_deadline_seconds: 30)

  """
  def create_subscription(project_id, topic_id, subscription_id, opts \\ []) do
    topic_path = topic_path(project_id, topic_id)
    subscription_path = subscription_path(project_id, subscription_id)
    
    operation = fn channel, _params ->
      request = %Google.Pubsub.V1.Subscription{
        name: subscription_path,
        topic: topic_path,
        ack_deadline_seconds: Keyword.get(opts, :ack_deadline_seconds, 60)
      }
      Google.Pubsub.V1.Subscriber.Stub.create_subscription(channel, request)
    end

    Client.execute(operation)
  end

  @doc """
  Deletes a subscription.

  ## Parameters
  - `project_id`: The Google Cloud project ID
  - `subscription_id`: The subscription identifier

  ## Returns
  - `:ok` - Successfully deleted subscription
  - `{:error, reason}` - Error deleting subscription

  """
  def delete_subscription(project_id, subscription_id) do
    subscription_path = subscription_path(project_id, subscription_id)
    
    operation = fn channel, _params ->
      request = %Google.Pubsub.V1.DeleteSubscriptionRequest{subscription: subscription_path}
      Google.Pubsub.V1.Subscriber.Stub.delete_subscription(channel, request)
    end

    case Client.execute(operation) do
      {:ok, %Google.Protobuf.Empty{}} -> :ok
      error -> error
    end
  end

  @doc """
  Pulls messages from a subscription.

  ## Parameters
  - `project_id`: The Google Cloud project ID
  - `subscription_id`: The subscription identifier
  - `max_messages`: Maximum number of messages to pull (default: 10)

  ## Returns
  - `{:ok, messages}` - List of received messages
  - `{:error, reason}` - Error pulling messages

  ## Examples

      {:ok, messages} = PubsubGrpc.pull("my-project", "my-sub")
      {:ok, messages} = PubsubGrpc.pull("my-project", "my-sub", 5)

      # Process messages
      Enum.each(messages, fn received_msg ->
        IO.puts("Received: \#{received_msg.message.data}")
        # Remember to acknowledge: PubsubGrpc.acknowledge(project, sub, [received_msg.ack_id])
      end)

  """
  def pull(project_id, subscription_id, max_messages \\ 10) do
    subscription_path = subscription_path(project_id, subscription_id)
    
    operation = fn channel, _params ->
      request = %Google.Pubsub.V1.PullRequest{
        subscription: subscription_path,
        max_messages: max_messages
      }
      Google.Pubsub.V1.Subscriber.Stub.pull(channel, request)
    end

    case Client.execute(operation) do
      {:ok, response} -> {:ok, response.received_messages}
      error -> error
    end
  end

  @doc """
  Acknowledges received messages.

  ## Parameters
  - `project_id`: The Google Cloud project ID
  - `subscription_id`: The subscription identifier
  - `ack_ids`: List of acknowledgment IDs from received messages

  ## Returns
  - `:ok` - Successfully acknowledged messages
  - `{:error, reason}` - Error acknowledging messages

  ## Examples

      {:ok, messages} = PubsubGrpc.pull("my-project", "my-sub")
      ack_ids = Enum.map(messages, & &1.ack_id)
      :ok = PubsubGrpc.acknowledge("my-project", "my-sub", ack_ids)

  """
  def acknowledge(project_id, subscription_id, ack_ids) when is_list(ack_ids) do
    subscription_path = subscription_path(project_id, subscription_id)
    
    operation = fn channel, _params ->
      request = %Google.Pubsub.V1.AcknowledgeRequest{
        subscription: subscription_path,
        ack_ids: ack_ids
      }
      Google.Pubsub.V1.Subscriber.Stub.acknowledge(channel, request)
    end

    case Client.execute(operation) do
      {:ok, %Google.Protobuf.Empty{}} -> :ok
      error -> error
    end
  end

  @doc """
  Executes a custom operation using a connection from the pool.

  This function allows you to execute custom Pub/Sub operations that aren't covered
  by the convenience functions above.

  ## Parameters
  - `operation_fn`: A function that takes `(channel, params)` and returns the operation result
  - `params`: Optional parameters to pass to the operation function

  ## Returns
  - Operation result from the GRPC call
  - `{:error, reason}` - Error executing operation

  ## Examples

      # Custom operation
      operation = fn channel, _params ->
        request = %Google.Pubsub.V1.GetTopicRequest{topic: "projects/my-project/topics/my-topic"}
        Google.Pubsub.V1.Publisher.Stub.get_topic(channel, request)
      end

      {:ok, topic} = PubsubGrpc.execute(operation)

  """
  def execute(operation_fn, params \\ []) do
    Client.execute(operation_fn, params)
  end

  @doc """
  Executes multiple operations using the same connection.

  This is more efficient when you need to perform several operations in sequence
  as it reuses the same connection instead of checking out a new one each time.

  ## Parameters
  - `fun`: A function that receives a channel and performs multiple operations

  ## Returns
  - Result of the function execution
  - `{:error, reason}` - Error executing operations

  ## Examples

      result = PubsubGrpc.with_connection(fn channel ->
        # Create topic
        topic_req = %Google.Pubsub.V1.Topic{name: "projects/my-project/topics/batch-topic"}
        {:ok, _topic} = Google.Pubsub.V1.Publisher.Stub.create_topic(channel, topic_req)
        
        # Publish message  
        msg = %Google.Pubsub.V1.PubsubMessage{data: "Batch message"}
        pub_req = %Google.Pubsub.V1.PublishRequest{
          topic: "projects/my-project/topics/batch-topic",
          messages: [msg]
        }
        Google.Pubsub.V1.Publisher.Stub.publish(channel, pub_req)
      end)

  """
  def with_connection(fun) when is_function(fun, 1) do
    Client.with_connection(fun)
  end

  # Private helper functions

  defp topic_path(project_id, topic_id) do
    "projects/#{project_id}/topics/#{topic_id}"
  end

  defp subscription_path(project_id, subscription_id) do
    "projects/#{project_id}/subscriptions/#{subscription_id}"
  end

  @doc """
  Hello world function for basic testing.

  ## Examples

      iex> PubsubGrpc.hello()
      :world

  """
  def hello do
    :world
  end
end
