defmodule PubsubGrpcTest do
  use ExUnit.Case
  doctest PubsubGrpc
  
  alias PubsubGrpc.Client
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

  test "basic hello function" do
    assert PubsubGrpc.hello() == :world
  end

  test "create topic", %{topic_name: topic_name} do
    topic_path = EmulatorHelper.topic_path(topic_name)
    
    create_topic_operation = fn channel, _params ->
      request = %Google.Pubsub.V1.Topic{
        name: topic_path
      }
      Google.Pubsub.V1.Publisher.Stub.create_topic(channel, request)
    end

    assert {:ok, %Google.Pubsub.V1.Topic{name: ^topic_path}} = Client.execute(create_topic_operation)
  end

  test "create subscription", %{topic_name: topic_name, subscription_name: subscription_name} do
    topic_path = EmulatorHelper.topic_path(topic_name)
    subscription_path = EmulatorHelper.subscription_path(subscription_name)
    
    # First create the topic
    create_topic_operation = fn channel, _params ->
      request = %Google.Pubsub.V1.Topic{name: topic_path}
      Google.Pubsub.V1.Publisher.Stub.create_topic(channel, request)
    end
    assert {:ok, _} = Client.execute(create_topic_operation)

    # Then create subscription
    create_subscription_operation = fn channel, _params ->
      request = %Google.Pubsub.V1.Subscription{
        name: subscription_path,
        topic: topic_path,
        ack_deadline_seconds: 60
      }
      Google.Pubsub.V1.Subscriber.Stub.create_subscription(channel, request)
    end

    assert {:ok, %Google.Pubsub.V1.Subscription{name: ^subscription_path, topic: ^topic_path}} = 
           Client.execute(create_subscription_operation)
  end

  test "publish message", %{topic_name: topic_name} do
    topic_path = EmulatorHelper.topic_path(topic_name)
    
    # Create topic first
    create_topic_operation = fn channel, _params ->
      request = %Google.Pubsub.V1.Topic{name: topic_path}
      Google.Pubsub.V1.Publisher.Stub.create_topic(channel, request)
    end
    assert {:ok, _} = Client.execute(create_topic_operation)

    # Publish message
    message_data = "Hello, Pub/Sub!"
    publish_operation = fn channel, _params ->
      message = %Google.Pubsub.V1.PubsubMessage{
        data: message_data,
        attributes: %{"test" => "true"}
      }

      request = %Google.Pubsub.V1.PublishRequest{
        topic: topic_path,
        messages: [message]
      }

      Google.Pubsub.V1.Publisher.Stub.publish(channel, request)
    end

    assert {:ok, %Google.Pubsub.V1.PublishResponse{message_ids: [message_id]}} = 
           Client.execute(publish_operation)
    
    assert is_binary(message_id)
    assert String.length(message_id) > 0
  end

  test "full workflow: create topic, subscription, publish, and pull", %{topic_name: topic_name, subscription_name: subscription_name} do
    topic_path = EmulatorHelper.topic_path(topic_name)
    subscription_path = EmulatorHelper.subscription_path(subscription_name)
    message_data = "Integration test message"

    # Step 1: Create topic
    create_topic_operation = fn channel, _params ->
      request = %Google.Pubsub.V1.Topic{name: topic_path}
      Google.Pubsub.V1.Publisher.Stub.create_topic(channel, request)
    end
    assert {:ok, _} = Client.execute(create_topic_operation)

    # Step 2: Create subscription
    create_subscription_operation = fn channel, _params ->
      request = %Google.Pubsub.V1.Subscription{
        name: subscription_path,
        topic: topic_path,
        ack_deadline_seconds: 60
      }
      Google.Pubsub.V1.Subscriber.Stub.create_subscription(channel, request)
    end
    assert {:ok, _} = Client.execute(create_subscription_operation)

    # Step 3: Publish message
    publish_operation = fn channel, _params ->
      message = %Google.Pubsub.V1.PubsubMessage{
        data: message_data,
        attributes: %{"source" => "integration_test", "timestamp" => "#{System.system_time()}"}
      }

      request = %Google.Pubsub.V1.PublishRequest{
        topic: topic_path,
        messages: [message]
      }

      Google.Pubsub.V1.Publisher.Stub.publish(channel, request)
    end
    assert {:ok, %Google.Pubsub.V1.PublishResponse{message_ids: [_message_id]}} = 
           Client.execute(publish_operation)

    # Step 4: Pull message
    pull_operation = fn channel, _params ->
      request = %Google.Pubsub.V1.PullRequest{
        subscription: subscription_path,
        max_messages: 1
      }
      Google.Pubsub.V1.Subscriber.Stub.pull(channel, request)
    end

    # Retry pulling a few times as message delivery can take a moment
    received_message = 
      Enum.find_value(1..5, fn _attempt ->
        case Client.execute(pull_operation) do
          {:ok, %Google.Pubsub.V1.PullResponse{received_messages: []}} ->
            :timer.sleep(500)
            nil
          {:ok, %Google.Pubsub.V1.PullResponse{received_messages: [message | _]}} ->
            message
          error ->
            flunk("Pull failed: #{inspect(error)}")
        end
      end)

    assert received_message != nil, "No message received after retries"

    # Verify message content
    assert %Google.Pubsub.V1.ReceivedMessage{
      ack_id: ack_id,
      message: %Google.Pubsub.V1.PubsubMessage{
        data: ^message_data,
        attributes: attributes
      }
    } = received_message

    assert attributes["source"] == "integration_test"
    assert is_binary(ack_id)

    # Step 5: Acknowledge message
    acknowledge_operation = fn channel, _params ->
      request = %Google.Pubsub.V1.AcknowledgeRequest{
        subscription: subscription_path,
        ack_ids: [ack_id]
      }
      Google.Pubsub.V1.Subscriber.Stub.acknowledge(channel, request)
    end
    
    assert {:ok, %Google.Protobuf.Empty{}} = Client.execute(acknowledge_operation)
  end

  test "multiple messages publish and pull", %{topic_name: topic_name, subscription_name: subscription_name} do
    topic_path = EmulatorHelper.topic_path(topic_name)
    subscription_path = EmulatorHelper.subscription_path(subscription_name)

    # Setup topic and subscription
    create_topic_operation = fn channel, _params ->
      request = %Google.Pubsub.V1.Topic{name: topic_path}
      Google.Pubsub.V1.Publisher.Stub.create_topic(channel, request)
    end
    assert {:ok, _} = Client.execute(create_topic_operation)

    create_subscription_operation = fn channel, _params ->
      request = %Google.Pubsub.V1.Subscription{
        name: subscription_path,
        topic: topic_path,
        ack_deadline_seconds: 60
      }
      Google.Pubsub.V1.Subscriber.Stub.create_subscription(channel, request)
    end
    assert {:ok, _} = Client.execute(create_subscription_operation)

    # Publish multiple messages
    message_count = 5
    messages = Enum.map(1..message_count, fn i ->
      %Google.Pubsub.V1.PubsubMessage{
        data: "Message #{i}",
        attributes: %{"index" => "#{i}"}
      }
    end)

    publish_operation = fn channel, _params ->
      request = %Google.Pubsub.V1.PublishRequest{
        topic: topic_path,
        messages: messages
      }
      Google.Pubsub.V1.Publisher.Stub.publish(channel, request)
    end

    assert {:ok, %Google.Pubsub.V1.PublishResponse{message_ids: message_ids}} = 
           Client.execute(publish_operation)
    assert length(message_ids) == message_count

    # Pull all messages
    pull_operation = fn channel, _params ->
      request = %Google.Pubsub.V1.PullRequest{
        subscription: subscription_path,
        max_messages: message_count
      }
      Google.Pubsub.V1.Subscriber.Stub.pull(channel, request)
    end

    # Retry until we get all messages
    received_messages = 
      Enum.reduce_while(1..10, [], fn _attempt, acc ->
        case Client.execute(pull_operation) do
          {:ok, %Google.Pubsub.V1.PullResponse{received_messages: []}} when acc == [] ->
            :timer.sleep(500)
            {:cont, acc}
          {:ok, %Google.Pubsub.V1.PullResponse{received_messages: new_messages}} ->
            all_messages = acc ++ new_messages
            if length(all_messages) >= message_count do
              {:halt, all_messages}
            else
              :timer.sleep(200)
              {:cont, all_messages}
            end
          error ->
            flunk("Pull failed: #{inspect(error)}")
        end
      end)

    assert length(received_messages) >= message_count, 
           "Expected at least #{message_count} messages, got #{length(received_messages)}"

    # Verify message content
    data_received = received_messages
                   |> Enum.map(& &1.message.data)
                   |> Enum.sort()

    expected_data = Enum.map(1..message_count, &"Message #{&1}")
                   |> Enum.sort()

    assert data_received == expected_data

    # Acknowledge all messages
    ack_ids = Enum.map(received_messages, & &1.ack_id)
    
    acknowledge_operation = fn channel, _params ->
      request = %Google.Pubsub.V1.AcknowledgeRequest{
        subscription: subscription_path,
        ack_ids: ack_ids
      }
      Google.Pubsub.V1.Subscriber.Stub.acknowledge(channel, request)
    end
    
    assert {:ok, %Google.Protobuf.Empty{}} = Client.execute(acknowledge_operation)
  end

  test "error handling: create topic that already exists", %{topic_name: topic_name} do
    topic_path = EmulatorHelper.topic_path(topic_name)
    
    create_topic_operation = fn channel, _params ->
      request = %Google.Pubsub.V1.Topic{name: topic_path}
      Google.Pubsub.V1.Publisher.Stub.create_topic(channel, request)
    end

    # First creation should succeed
    assert {:ok, _} = Client.execute(create_topic_operation)

    # Second creation should fail
    assert {:error, %GRPC.RPCError{status: 6, message: message}} = Client.execute(create_topic_operation)
    assert message =~ "already exists" or message =~ "ALREADY_EXISTS"
  end
end
