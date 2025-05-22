defmodule PubsubGrpc.Publisher do
  @moduledoc """
  Functions for interacting with the Google Pub/Sub Publisher API.
  """

  alias PubsubGrpc.MessageBuilder

  @doc """
  Creates a new topic in Google Pub/Sub.

  ## Parameters
  - name: The fully-qualified topic name (projects/{project}/topics/{topic})
  - opts: Additional options (labels, etc.)

  ## Returns
  {:ok, topic} on success, {:error, reason} on failure

  ## Example
      iex> PubsubGrpc.Publisher.create_topic("projects/my-project/topics/my-topic")
      {:ok, %Google.Pubsub.V1.Topic{...}}
  """
  def create_topic(name, opts \\ []) do
    labels = Keyword.get(opts, :labels, %{})

    topic = MessageBuilder.build_topic(name, labels)

    with {:ok, channel} <- get_channel(),
         {:ok, response} <- Google.Pubsub.V1.Publisher.Stub.create_topic(channel, topic) do
      {:ok, response}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Publishes a JSON message or list of messages to a topic.

  ## Parameters
  - topic_name: The fully-qualified topic name (projects/{project}/topics/{topic})
  - data: A JSON-serializable map or list of maps to publish
  - opts: Additional options (attributes, etc.)

  ## Returns
  {:ok, publish_response} on success, {:error, reason} on failure

  ## Example
      iex> PubsubGrpc.Publisher.publish_json("projects/my-project/topics/my-topic", %{id: 123})
      {:ok, %Google.Pubsub.V1.PublishResponse{...}}
  """
  def publish_json(topic_name, data, opts \\ []) do
    attributes = Keyword.get(opts, :attributes, %{})

    # Handle both single messages and lists of messages
    messages = cond do
      is_list(data) and Enum.all?(data, &is_map/1) ->
        Enum.map(data, &MessageBuilder.build_message(&1, attributes))
      is_map(data) ->
        MessageBuilder.build_message(data, attributes)
      true ->
        raise ArgumentError, "Data must be a map or a list of maps"
    end

    publish_request = MessageBuilder.build_publish_request(topic_name, messages)

    with {:ok, channel} <- get_channel(),
         {:ok, response} <- Google.Pubsub.V1.Publisher.Stub.publish(channel, publish_request) do
      {:ok, response}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  # Private function to get a connection channel from the pool
  defp get_channel do
    case Poolex.run(PubsubGrpc.Connection, fn pid ->
      GenServer.call(pid, :get_connection)
    end, checkout_timeout: 5_000) do
      {:ok, channel} -> {:ok, channel}
      error -> {:error, error}
    end
  end
end
