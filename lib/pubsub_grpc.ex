defmodule PubsubGrpc do
  @moduledoc """
  A library for interacting with Google Cloud Pub/Sub using gRPC.

  This module provides a simple interface for creating topics and publishing
  JSON messages to Google Cloud Pub/Sub.
  """

  alias PubsubGrpc.Publisher

  @doc """
  Creates a new topic in Google Pub/Sub.

  ## Parameters
  - topic_name: The name of the topic to create
  - opts: Additional options (project_id, labels, etc.)

  If project_id is not provided in opts, it will be read from the configuration.

  ## Returns
  {:ok, topic} on success, {:error, reason} on failure

  ## Example
      iex> PubsubGrpc.create_topic("my-topic")
      {:ok, %Google.Pubsub.V1.Topic{...}}
  """
  defdelegate create_topic(topic_name, opts \\ []), to: Publisher

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
      iex> PubsubGrpc.publish_json("my-topic", %{id: 123})
      {:ok, %Google.Pubsub.V1.PublishResponse{...}}
  """
  defdelegate publish_json(topic_name, data, opts \\ []), to: Publisher
end
