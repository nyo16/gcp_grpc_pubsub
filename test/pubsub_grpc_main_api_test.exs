defmodule PubsubGrpcMainApiTest do
  use ExUnit.Case
  doctest PubsubGrpc

  alias PubsubGrpc.EmulatorHelper

  @moduletag :integration

  setup do
    # Generate unique names for each test
    topic_name = EmulatorHelper.test_topic_name()
    subscription_name = EmulatorHelper.test_subscription_name()

    # Cleanup after each test
    on_exit(fn ->
      EmulatorHelper.cleanup_subscription(subscription_name)
      EmulatorHelper.cleanup_topic(topic_name)
    end)

    %{topic_name: topic_name, subscription_name: subscription_name}
  end

  test "create_topic using main API", %{topic_name: topic_name} do
    assert {:ok, topic} = PubsubGrpc.create_topic("test-project-id", topic_name)
    assert topic.name == "projects/test-project-id/topics/#{topic_name}"
  end

  test "delete_topic using main API", %{topic_name: topic_name} do
    # First create a topic
    {:ok, _topic} = PubsubGrpc.create_topic("test-project-id", topic_name)
    
    # Then delete it
    assert :ok = PubsubGrpc.delete_topic("test-project-id", topic_name)
    
    # Verify it's gone by trying to create it again (should succeed)
    assert {:ok, _topic} = PubsubGrpc.create_topic("test-project-id", topic_name)
  end

  test "list_topics using main API" do
    # Create a unique topic for this test
    topic_name = "list-test-#{:os.system_time(:millisecond)}"
    {:ok, _topic} = PubsubGrpc.create_topic("test-project-id", topic_name)
    
    # List topics
    {:ok, result} = PubsubGrpc.list_topics("test-project-id")
    
    # Should contain our topic
    topic_names = Enum.map(result.topics, fn topic -> topic.name end)
    assert "projects/test-project-id/topics/#{topic_name}" in topic_names
    
    # Cleanup
    PubsubGrpc.delete_topic("test-project-id", topic_name)
  end

  test "publish_message using main API", %{topic_name: topic_name} do
    # Create topic first
    {:ok, _topic} = PubsubGrpc.create_topic("test-project-id", topic_name)
    
    # Publish single message
    {:ok, response} = PubsubGrpc.publish_message("test-project-id", topic_name, "Hello World!")
    assert length(response.message_ids) == 1
    
    # Publish message with attributes
    {:ok, response} = PubsubGrpc.publish_message("test-project-id", topic_name, "Hello with attrs!", %{"source" => "test"})
    assert length(response.message_ids) == 1
  end

  test "publish using main API", %{topic_name: topic_name} do
    # Create topic first
    {:ok, _topic} = PubsubGrpc.create_topic("test-project-id", topic_name)
    
    # Publish multiple messages
    messages = [
      %{data: "Message 1", attributes: %{"index" => "1"}},
      %{data: "Message 2", attributes: %{"index" => "2"}},
      %{data: "Message 3"}
    ]
    
    {:ok, response} = PubsubGrpc.publish("test-project-id", topic_name, messages)
    assert length(response.message_ids) == 3
  end

  test "create_subscription using main API", %{topic_name: topic_name, subscription_name: subscription_name} do
    # Create topic first
    {:ok, _topic} = PubsubGrpc.create_topic("test-project-id", topic_name)
    
    # Create subscription
    {:ok, subscription} = PubsubGrpc.create_subscription("test-project-id", topic_name, subscription_name)
    assert subscription.name == "projects/test-project-id/subscriptions/#{subscription_name}"
    assert subscription.topic == "projects/test-project-id/topics/#{topic_name}"
    
    # Create subscription with custom ack deadline
    sub_name_2 = "#{subscription_name}-2"
    {:ok, subscription} = PubsubGrpc.create_subscription("test-project-id", topic_name, sub_name_2, ack_deadline_seconds: 30)
    assert subscription.ack_deadline_seconds == 30
    
    # Cleanup
    PubsubGrpc.delete_subscription("test-project-id", sub_name_2)
  end

  test "delete_subscription using main API", %{topic_name: topic_name, subscription_name: subscription_name} do
    # Create topic and subscription
    {:ok, _topic} = PubsubGrpc.create_topic("test-project-id", topic_name)
    {:ok, _subscription} = PubsubGrpc.create_subscription("test-project-id", topic_name, subscription_name)
    
    # Delete subscription
    assert :ok = PubsubGrpc.delete_subscription("test-project-id", subscription_name)
  end

  test "full workflow using main API", %{topic_name: topic_name, subscription_name: subscription_name} do
    # Create topic
    {:ok, _topic} = PubsubGrpc.create_topic("test-project-id", topic_name)
    
    # Create subscription
    {:ok, _subscription} = PubsubGrpc.create_subscription("test-project-id", topic_name, subscription_name)
    
    # Publish messages
    messages = [
      %{data: "Workflow message 1", attributes: %{"type" => "test"}},
      %{data: "Workflow message 2", attributes: %{"type" => "test"}}
    ]
    {:ok, _response} = PubsubGrpc.publish("test-project-id", topic_name, messages)
    
    # Pull messages (may need retry as delivery can take time)
    received_messages = 
      Enum.reduce_while(1..5, [], fn _attempt, acc ->
        case PubsubGrpc.pull("test-project-id", subscription_name, 5) do
          {:ok, []} when acc == [] ->
            :timer.sleep(500)
            {:cont, acc}
          {:ok, new_messages} ->
            all_messages = acc ++ new_messages
            if length(all_messages) >= 2 do
              {:halt, all_messages}
            else
              :timer.sleep(200)
              {:cont, all_messages}
            end
        end
      end)
    
    assert length(received_messages) >= 2
    
    # Verify message content
    message_data = Enum.map(received_messages, & &1.message.data)
    assert "Workflow message 1" in message_data
    assert "Workflow message 2" in message_data
    
    # Acknowledge messages
    ack_ids = Enum.map(received_messages, & &1.ack_id)
    assert :ok = PubsubGrpc.acknowledge("test-project-id", subscription_name, ack_ids)
  end

  test "with_connection using main API", %{topic_name: topic_name} do
    result = PubsubGrpc.with_connection(fn channel ->
      # Create topic using direct GRPC call
      topic_path = "projects/test-project-id/topics/#{topic_name}"
      request = %Google.Pubsub.V1.Topic{name: topic_path}
      Google.Pubsub.V1.Publisher.Stub.create_topic(channel, request)
    end)
    
    assert {:ok, topic} = result
    assert topic.name == "projects/test-project-id/topics/#{topic_name}"
  end

  test "execute custom operation using main API" do
    # Test a custom operation - getting a topic that doesn't exist
    operation = fn channel, _params ->
      request = %Google.Pubsub.V1.GetTopicRequest{
        topic: "projects/test-project-id/topics/non-existent-topic"
      }
      Google.Pubsub.V1.Publisher.Stub.get_topic(channel, request)
    end

    assert {:error, %GRPC.RPCError{status: 5}} = PubsubGrpc.execute(operation)
  end
end