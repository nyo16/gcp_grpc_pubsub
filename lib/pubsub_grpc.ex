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
  - name: The fully-qualified topic name (projects/{project}/topics/{topic})
  - opts: Additional options (labels, etc.)

  ## Returns
  {:ok, topic} on success, {:error, reason} on failure

  ## Example
      iex> PubsubGrpc.create_topic("projects/my-project/topics/my-topic")
      {:ok, %Google.Pubsub.V1.Topic{...}}
  """
  defdelegate create_topic(name, opts \\ []), to: Publisher

  @doc """
  Publishes a JSON message or list of messages to a topic.

  ## Parameters
  - topic_name: The fully-qualified topic name (projects/{project}/topics/{topic})
  - data: A JSON-serializable map or list of maps to publish
  - opts: Additional options (attributes, etc.)

  ## Returns
  {:ok, publish_response} on success, {:error, reason} on failure

  ## Example
      iex> PubsubGrpc.publish_json("projects/my-project/topics/my-topic", %{id: 123})
      {:ok, %Google.Pubsub.V1.PublishResponse{...}}
  """
  defdelegate publish_json(topic_name, data, opts \\ []), to: Publisher
end
