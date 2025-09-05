defmodule PubsubGrpc.Example do
  @moduledoc """
  Example usage of PubsubGrpc with DBConnection pooling
  """

  alias PubsubGrpc.Client

  @doc """
  Example of creating a topic using the connection pool
  """
  def create_topic_example(project_id, topic_id) do
    operation = fn channel, _params ->
      topic_name = "projects/#{project_id}/topics/#{topic_id}"
      
      request = %Google.Pubsub.V1.Topic{
        name: topic_name
      }

      Google.Pubsub.V1.Publisher.Stub.create_topic(channel, request)
    end

    Client.execute(operation)
  end

  @doc """
  Example of publishing messages using the connection pool
  """
  def publish_example(project_id, topic_id, messages) when is_list(messages) do
    operation = fn channel, params ->
      topic_name = "projects/#{project_id}/topics/#{topic_id}"
      
      pubsub_messages = Enum.map(params, fn message ->
        %Google.Pubsub.V1.PubsubMessage{
          data: Base.encode64(message)
        }
      end)

      request = %Google.Pubsub.V1.PublishRequest{
        topic: topic_name,
        messages: pubsub_messages
      }

      Google.Pubsub.V1.Publisher.Stub.publish(channel, request)
    end

    Client.execute(operation, messages)
  end

  @doc """
  Example of using connection directly for more complex operations
  """
  def complex_operation_example(project_id, topic_id) do
    Client.with_connection(fn conn ->
      # Create topic
      create_topic_op = fn channel, _params ->
        topic_name = "projects/#{project_id}/topics/#{topic_id}"
        request = %Google.Pubsub.V1.Topic{name: topic_name}
        Google.Pubsub.V1.Publisher.Stub.create_topic(channel, request)
      end

      # Publish message
      publish_op = fn channel, _params ->
        topic_name = "projects/#{project_id}/topics/#{topic_id}"
        message = %Google.Pubsub.V1.PubsubMessage{
          data: Base.encode64("Hello, World!")
        }
        request = %Google.Pubsub.V1.PublishRequest{
          topic: topic_name,
          messages: [message]
        }
        Google.Pubsub.V1.Publisher.Stub.publish(channel, request)
      end

      with {:ok, _topic} <- PubsubGrpc.Connection.execute(conn, create_topic_op),
           {:ok, result} <- PubsubGrpc.Connection.execute(conn, publish_op) do
        {:ok, result}
      else
        error -> error
      end
    end)
  end
end