defmodule PubsubGrpc.ClientTest do
  @moduledoc """
  Tests for the low-level `PubsubGrpc.Client`: raw stub calls whose results are
  returned unmodified. The high-level flows live in `PubsubGrpcMainApiTest`.
  """
  use ExUnit.Case, async: true

  import PubsubGrpc.EmulatorHelper,
    only: [unique_resources: 1, topic_path: 1, subscription_path: 1]

  alias PubsubGrpc.Client
  alias PubsubGrpc.Proto.Google.Pubsub.V1, as: PubsubV1
  alias PubsubV1.Publisher.Stub, as: PublisherStub
  alias PubsubV1.Subscriber.Stub, as: SubscriberStub

  @moduletag :integration

  setup :unique_resources

  test "execute/2 returns the raw stub result", %{topic_name: topic_name} do
    topic_path = topic_path(topic_name)

    assert {:ok, {:ok, %PubsubV1.Topic{name: ^topic_path}}} =
             Client.execute(&PublisherStub.create_topic(&1, %PubsubV1.Topic{name: topic_path}))
  end

  test "execute/2 returns gRPC errors unmapped", %{topic_name: topic_name} do
    create = &PublisherStub.create_topic(&1, %PubsubV1.Topic{name: topic_path(topic_name)})

    assert {:ok, {:ok, _}} = Client.execute(create)

    assert {:ok, {:error, %GRPC.RPCError{status: 6, message: message}}} = Client.execute(create)
    assert message =~ ~r/already exists|ALREADY_EXISTS/
  end

  test "raw stubs support a publish/pull/ack round trip", %{
    topic_name: topic_name,
    subscription_name: subscription_name
  } do
    topic_path = topic_path(topic_name)
    subscription_path = subscription_path(subscription_name)

    assert {:ok, {:ok, _}} =
             Client.execute(&PublisherStub.create_topic(&1, %PubsubV1.Topic{name: topic_path}))

    subscription = %PubsubV1.Subscription{
      name: subscription_path,
      topic: topic_path,
      ack_deadline_seconds: 60
    }

    assert {:ok, {:ok, %PubsubV1.Subscription{name: ^subscription_path}}} =
             Client.execute(&SubscriberStub.create_subscription(&1, subscription))

    publish = %PubsubV1.PublishRequest{
      topic: topic_path,
      messages: [%PubsubV1.PubsubMessage{data: "raw", attributes: %{"via" => "client"}}]
    }

    assert {:ok, {:ok, %PubsubV1.PublishResponse{message_ids: [message_id]}}} =
             Client.execute(&PublisherStub.publish(&1, publish))

    pull = %PubsubV1.PullRequest{subscription: subscription_path, max_messages: 1}

    received =
      PubsubGrpc.Eventually.eventually(fn ->
        case Client.execute(&SubscriberStub.pull(&1, pull)) do
          {:ok, {:ok, %PubsubV1.PullResponse{received_messages: [message]}}} -> message
          {:ok, {:ok, %PubsubV1.PullResponse{received_messages: []}}} -> nil
        end
      end)

    assert %PubsubV1.ReceivedMessage{
             ack_id: ack_id,
             message: %PubsubV1.PubsubMessage{
               message_id: ^message_id,
               data: "raw",
               attributes: %{"via" => "client"}
             }
           } = received

    ack = %PubsubV1.AcknowledgeRequest{subscription: subscription_path, ack_ids: [ack_id]}

    assert {:ok, {:ok, %Google.Protobuf.Empty{}}} =
             Client.execute(&SubscriberStub.acknowledge(&1, ack))
  end

  test "deprecated with_connection/2 behaves like execute/2" do
    # apply/3 so the deprecated call doesn't emit a compile-time warning.
    # credo:disable-for-next-line Credo.Check.Refactor.Apply
    result = apply(Client, :with_connection, [fn %GRPC.Channel{} -> {:ok, :value} end])
    assert {:ok, {:ok, :value}} = result
  end

  test "status/1 reports the application pool" do
    PubsubGrpc.Eventually.eventually(fn -> Client.status().status == :healthy end)
    assert %{pool_name: PubsubGrpc.ConnectionPool, status: :healthy} = Client.status()
  end

  test "a pool that does not exist returns {:error, :not_connected}" do
    pool = :"missing_pool_#{System.unique_integer([:positive])}"

    assert {:error, :not_connected} =
             Client.execute(fn _ -> flunk("callback must not run") end, pool: pool, timeout: 50)

    assert %{error: :pool_not_found} = Client.status(pool: pool)
  end
end
