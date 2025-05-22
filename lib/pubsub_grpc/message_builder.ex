defmodule PubsubGrpc.MessageBuilder do
  @moduledoc """
  Helper module to build Pub/Sub message structures for gRPC interactions.
  Focused on topic creation and message publishing with JSON.
  """

  @doc """
  Builds a Topic struct with the given name.

  ## Parameters
  - name: The fully-qualified topic name, typically in the format:
          "projects/{project}/topics/{topic}"
  - labels: (Optional) A map of labels to apply to the topic

  ## Returns
  A Google.Pubsub.V1.Topic struct ready to be used with the Publisher API.

  ## Example
      iex> PubsubGrpc.MessageBuilder.build_topic("projects/my-project/topics/my-topic")
  """
  def build_topic(name, labels \\ %{}) do
    %Google.Pubsub.V1.Topic{
      name: name,
      labels: labels
    }
  end

  @doc """
  Creates a PubsubMessage struct from JSON data.

  ## Parameters
  - data: A map or JSON-encodable structure to be sent as the message data
  - attributes: (Optional) A map of string attributes to attach to the message

  ## Returns
  A Google.Pubsub.V1.PubsubMessage struct ready for publishing.

  ## Example
      iex> PubsubGrpc.MessageBuilder.build_message(%{id: 123, name: "test"})
  """
  def build_message(data, attributes \\ %{}) do
    # Convert the data to JSON and then to binary
    json_data = Jason.encode!(data)

    %Google.Pubsub.V1.PubsubMessage{
      data: json_data,
      attributes: attributes
    }
  end

  @doc """
  Creates a PublishRequest for publishing one or more messages to a topic.

  ## Parameters
  - topic_name: The fully-qualified topic name, typically in the format:
                "projects/{project}/topics/{topic}"
  - messages: A single message or list of Google.Pubsub.V1.PubsubMessage structs

  ## Returns
  A Google.Pubsub.V1.PublishRequest struct ready to be sent to the Publisher API.

  ## Example
      iex> message = PubsubGrpc.MessageBuilder.build_message(%{id: 123})
      iex> PubsubGrpc.MessageBuilder.build_publish_request("projects/my-project/topics/my-topic", message)
  """
  def build_publish_request(topic_name, messages) do
    # Ensure messages is a list
    messages_list = if is_list(messages), do: messages, else: [messages]

    %Google.Pubsub.V1.PublishRequest{
      topic: topic_name,
      messages: messages_list
    }
  end
end
