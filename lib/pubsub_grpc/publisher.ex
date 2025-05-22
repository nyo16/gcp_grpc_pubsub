defmodule PubsubGrpc.Publisher do
  @moduledoc """
  Functions for interacting with the Google Pub/Sub Publisher API.
  """

  alias PubsubGrpc.MessageBuilder

  # Get the default project ID from config
  defp default_project_id do
    case Application.get_env(:pubsub_grpc, :emulator) do
      [project_id: project_id, host: _host, port: _port] -> project_id
      _ -> nil
    end
  end

  @doc """
  Creates a new topic in Google Pub/Sub.

  ## Parameters
  - topic_name: The name of the topic to create
  - opts: Additional options (project_id, labels, etc.)

  If project_id is not provided in opts, it will be read from the configuration.

  ## Returns
  {:ok, topic} on success, {:error, reason} on failure

  ## Example
      iex> PubsubGrpc.Publisher.create_topic("my-topic")
      {:ok, %Google.Pubsub.V1.Topic{...}}
  """
  def create_topic(topic_name, opts \\ []) do
    project_id = Keyword.get(opts, :project_id, default_project_id())

    unless project_id do
      raise ArgumentError, "project_id must be provided either in opts or in configuration"
    end
    labels = Keyword.get(opts, :labels, %{})

    # Build the fully-qualified topic name
    full_topic_name = "projects/#{project_id}/topics/#{topic_name}"

    topic = MessageBuilder.build_topic(full_topic_name, labels)

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
  - topic_name: The name of the topic to publish to
  - data: A JSON-serializable map or list of maps to publish
  - opts: Additional options (project_id, attributes, etc.)

  If project_id is not provided in opts, it will be read from the configuration.

  ## Returns
  {:ok, publish_response} on success, {:error, reason} on failure

  ## Example
      iex> PubsubGrpc.Publisher.publish_json("my-topic", %{id: 123})
      {:ok, %Google.Pubsub.V1.PublishResponse{...}}
  """
  def publish_json(topic_name, data, opts \\ []) do
    project_id = Keyword.get(opts, :project_id, default_project_id())

    unless project_id do
      raise ArgumentError, "project_id must be provided either in opts or in configuration"
    end
    attributes = Keyword.get(opts, :attributes, %{})

    # Build the fully-qualified topic name
    full_topic_name = "projects/#{project_id}/topics/#{topic_name}"

    # Handle both single messages and lists of messages
    messages = cond do
      is_list(data) and Enum.all?(data, &is_map/1) ->
        Enum.map(data, &MessageBuilder.build_message(&1, attributes))
      is_map(data) ->
        MessageBuilder.build_message(data, attributes)
      true ->
        raise ArgumentError, "Data must be a map or a list of maps"
    end

    publish_request = MessageBuilder.build_publish_request(full_topic_name, messages)

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
