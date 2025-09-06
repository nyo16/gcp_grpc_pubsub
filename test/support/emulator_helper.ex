defmodule PubsubGrpc.EmulatorHelper do
  @moduledoc """
  Helper module for managing the Pub/Sub emulator during tests
  """

  @project_id "my-project-id"
  @emulator_host "localhost"
  @emulator_port 8085

  @doc """
  Start the emulator using Docker Compose
  """
  def start_emulator do
    case System.cmd("docker-compose", ["up", "-d", "pubsub-emulator"], stderr_to_stdout: true) do
      {output, 0} ->
        IO.puts("Emulator started: #{output}")
        wait_for_emulator()
        :ok

      {error, _} ->
        IO.puts("Failed to start emulator: #{error}")
        {:error, :emulator_start_failed}
    end
  end

  @doc """
  Stop the emulator
  """
  def stop_emulator do
    System.cmd("docker-compose", ["down"], stderr_to_stdout: true)
    :ok
  end

  @doc """
  Wait for the emulator to be ready
  """
  def wait_for_emulator(retries \\ 30) do
    if retries <= 0 do
      raise "Emulator failed to start within timeout"
    end

    case :gen_tcp.connect(
           String.to_charlist(@emulator_host),
           @emulator_port,
           [:binary, active: false],
           1000
         ) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        :ok

      {:error, _} ->
        :timer.sleep(1000)
        wait_for_emulator(retries - 1)
    end
  end

  @doc """
  Get project ID for tests
  """
  def project_id, do: @project_id

  @doc """
  Generate unique test topic name
  """
  def test_topic_name(suffix \\ nil) do
    base = "test-topic-#{:os.system_time(:millisecond)}"
    if suffix, do: "#{base}-#{suffix}", else: base
  end

  @doc """
  Generate unique test subscription name
  """
  def test_subscription_name(suffix \\ nil) do
    base = "test-subscription-#{:os.system_time(:millisecond)}"
    if suffix, do: "#{base}-#{suffix}", else: base
  end

  @doc """
  Create full topic path
  """
  def topic_path(topic_name) do
    "projects/#{@project_id}/topics/#{topic_name}"
  end

  @doc """
  Create full subscription path
  """
  def subscription_path(subscription_name) do
    "projects/#{@project_id}/subscriptions/#{subscription_name}"
  end

  @doc """
  Clean up resources after test
  """
  def cleanup_topic(topic_name) do
    topic_path = topic_path(topic_name)

    delete_topic_operation = fn channel, _params ->
      request = %Google.Pubsub.V1.DeleteTopicRequest{
        topic: topic_path
      }

      Google.Pubsub.V1.Publisher.Stub.delete_topic(channel, request)
    end

    case PubsubGrpc.Client.execute(delete_topic_operation) do
      {:ok, _} -> :ok
      # Ignore errors during cleanup
      {:error, _} -> :ok
      # Handle bare :ok returns
      :ok -> :ok
      # Handle bare :error returns
      :error -> :ok
      # Ignore any other result during cleanup
      _ -> :ok
    end
  end

  @doc """
  Clean up subscription after test
  """
  def cleanup_subscription(subscription_name) do
    subscription_path = subscription_path(subscription_name)

    delete_subscription_operation = fn channel, _params ->
      request = %Google.Pubsub.V1.DeleteSubscriptionRequest{
        subscription: subscription_path
      }

      Google.Pubsub.V1.Subscriber.Stub.delete_subscription(channel, request)
    end

    case PubsubGrpc.Client.execute(delete_subscription_operation) do
      {:ok, _} -> :ok
      # Ignore errors during cleanup
      {:error, _} -> :ok
      # Handle bare :ok returns
      :ok -> :ok
      # Handle bare :error returns
      :error -> :ok
      # Ignore any other result during cleanup
      _ -> :ok
    end
  end
end
