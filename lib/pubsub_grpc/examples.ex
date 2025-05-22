defmodule PubsubGrpc.Examples do
  @moduledoc """
  Example usage of the PubsubGrpc library.

  This module contains examples of how to use the PubsubGrpc library to interact
  with Google Cloud Pub/Sub. These examples are meant to be run in an IEx session
  or used as a reference for implementing your own Pub/Sub interactions.
  """

  @doc """
  Example of creating a topic and publishing a message to it.

  ## Usage

  First, ensure the Pub/Sub emulator is running:

  ```bash
  docker-compose up -d
  ```

  Then, in an IEx session:

  ```elixir
  # Start the application
  iex -S mix

  # Run the example
  PubsubGrpc.Examples.create_and_publish()
  ```
  """
  def create_and_publish do
    # Topic name to create
    topic_name = "example-topic"

    # Create a topic (project_id will be read from config)
    IO.puts("Creating topic: #{topic_name}")

    case PubsubGrpc.create_topic(topic_name) do
      {:ok, topic} ->
        IO.puts("Topic created successfully: #{inspect(topic.name)}")

        # Create a sample message
        message = %{
          id: "msg-#{:rand.uniform(1000)}",
          timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
          data: %{
            temperature: 22.5,
            humidity: 45.2,
            location: "Room A"
          }
        }

        # Publish the message
        IO.puts("Publishing message: #{inspect(message)}")

        case PubsubGrpc.publish_json(topic_name, message) do
          {:ok, response} ->
            IO.puts("Message published successfully!")
            IO.puts("Message IDs: #{inspect(response.message_ids)}")
            :ok

          {:error, reason} ->
            IO.puts("Failed to publish message: #{inspect(reason)}")
            {:error, reason}
        end

      {:error, reason} ->
        IO.puts("Failed to create topic: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Example of publishing multiple messages to an existing topic.

  ## Usage

  ```elixir
  # Start the application
  iex -S mix

  # Run the example
  PubsubGrpc.Examples.publish_multiple("my-topic")
  ```
  """
  def publish_multiple(topic_name) do
    # Create multiple sample messages
    messages = for i <- 1..5 do
      %{
        id: "batch-msg-#{i}",
        timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
        data: %{
          value: i * 10,
          name: "Sample #{i}"
        }
      }
    end

    # Publish the messages (project_id will be read from config)
    IO.puts("Publishing #{length(messages)} messages to topic: #{topic_name}")

    case PubsubGrpc.publish_json(topic_name, messages) do
      {:ok, response} ->
        IO.puts("Messages published successfully!")
        IO.puts("Message IDs: #{inspect(response.message_ids)}")
        :ok

      {:error, reason} ->
        IO.puts("Failed to publish messages: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
