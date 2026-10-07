defmodule PubsubGrpcMainApiTest do
  use ExUnit.Case, async: true

  import PubsubGrpc.EmulatorHelper,
    only: [
      unique_resources: 1,
      unique_name: 1,
      track_topic: 1,
      track_subscription: 1,
      list_all: 2
    ]

  import PubsubGrpc.Eventually

  alias Google.Pubsub.V1, as: PubsubV1
  alias PubsubGrpc.Error
  alias PubsubV1.Publisher.Stub, as: PublisherStub

  @moduletag :integration

  @project "test-project-id"

  setup :unique_resources

  test "create_topic using main API", %{topic_name: topic_name} do
    assert {:ok, %PubsubV1.Topic{name: name}} = PubsubGrpc.create_topic(@project, topic_name)
    assert name == "projects/#{@project}/topics/#{topic_name}"
  end

  test "delete_topic removes the topic", %{topic_name: topic_name} do
    {:ok, _topic} = PubsubGrpc.create_topic(@project, topic_name)

    assert :ok = PubsubGrpc.delete_topic(@project, topic_name)
    assert {:error, %Error{code: :not_found}} = PubsubGrpc.get_topic(@project, topic_name)
  end

  test "list_topics using main API" do
    topic_name = track_topic(unique_name("list-test"))
    {:ok, _topic} = PubsubGrpc.create_topic(@project, topic_name)

    assert {:ok, %{topics: _, next_page_token: token}} = PubsubGrpc.list_topics(@project)
    assert is_binary(token)

    topics = list_all(:topics, &PubsubGrpc.list_topics(@project, &1))
    assert "projects/#{@project}/topics/#{topic_name}" in Enum.map(topics, & &1.name)
  end

  test "publish_message round-trips data and attributes", %{
    topic_name: topic_name,
    subscription_name: subscription_name
  } do
    {:ok, _topic} = PubsubGrpc.create_topic(@project, topic_name)
    {:ok, _sub} = PubsubGrpc.create_subscription(@project, topic_name, subscription_name)

    assert {:ok, %{message_ids: [plain_id]}} =
             PubsubGrpc.publish_message(@project, topic_name, "Hello World!")

    assert {:ok, %{message_ids: [attrs_id]}} =
             PubsubGrpc.publish_message(@project, topic_name, "Hello with attrs!", %{
               "source" => "test"
             })

    by_id =
      @project
      |> pull_until(subscription_name, 2)
      |> Map.new(&{&1.message.message_id, &1.message})

    assert %{data: "Hello World!", attributes: plain_attrs} = by_id[plain_id]
    assert plain_attrs == %{}
    assert %{data: "Hello with attrs!", attributes: %{"source" => "test"}} = by_id[attrs_id]
  end

  test "publish sends a batch and every message round-trips", %{
    topic_name: topic_name,
    subscription_name: subscription_name
  } do
    {:ok, _topic} = PubsubGrpc.create_topic(@project, topic_name)
    {:ok, _sub} = PubsubGrpc.create_subscription(@project, topic_name, subscription_name)

    messages = [
      %{data: "Message 1", attributes: %{"index" => "1"}},
      %{data: "Message 2", attributes: %{"index" => "2"}},
      %{data: "Message 3"}
    ]

    assert {:ok, %{message_ids: ids}} = PubsubGrpc.publish(@project, topic_name, messages)
    assert length(ids) == 3
    assert ids == Enum.uniq(ids)

    received =
      @project
      |> pull_until(subscription_name, 3)
      |> Map.new(&{&1.message.message_id, {&1.message.data, &1.message.attributes}})

    # message_ids are returned in publish order.
    assert received == %{
             Enum.at(ids, 0) => {"Message 1", %{"index" => "1"}},
             Enum.at(ids, 1) => {"Message 2", %{"index" => "2"}},
             Enum.at(ids, 2) => {"Message 3", %{}}
           }
  end

  test "create_subscription using main API", %{
    topic_name: topic_name,
    subscription_name: subscription_name
  } do
    {:ok, _topic} = PubsubGrpc.create_topic(@project, topic_name)

    assert {:ok, subscription} =
             PubsubGrpc.create_subscription(@project, topic_name, subscription_name)

    assert subscription.name == "projects/#{@project}/subscriptions/#{subscription_name}"
    assert subscription.topic == "projects/#{@project}/topics/#{topic_name}"

    sub_name_2 = track_subscription(unique_name("test-subscription"))

    assert {:ok, %PubsubV1.Subscription{ack_deadline_seconds: 30}} =
             PubsubGrpc.create_subscription(@project, topic_name, sub_name_2,
               ack_deadline_seconds: 30
             )
  end

  test "delete_subscription removes the subscription", %{
    topic_name: topic_name,
    subscription_name: subscription_name
  } do
    {:ok, _topic} = PubsubGrpc.create_topic(@project, topic_name)
    {:ok, _sub} = PubsubGrpc.create_subscription(@project, topic_name, subscription_name)

    assert :ok = PubsubGrpc.delete_subscription(@project, subscription_name)

    assert {:error, %Error{code: :not_found}} =
             PubsubGrpc.get_subscription(@project, subscription_name)
  end

  test "full workflow using main API", %{
    topic_name: topic_name,
    subscription_name: subscription_name
  } do
    {:ok, _topic} = PubsubGrpc.create_topic(@project, topic_name)
    {:ok, _sub} = PubsubGrpc.create_subscription(@project, topic_name, subscription_name)

    messages = [
      %{data: "Workflow message 1", attributes: %{"type" => "test"}},
      %{data: "Workflow message 2", attributes: %{"type" => "test"}}
    ]

    {:ok, _response} = PubsubGrpc.publish(@project, topic_name, messages)

    received = pull_until(@project, subscription_name, 2)

    assert received |> Enum.map(& &1.message.data) |> Enum.sort() ==
             ["Workflow message 1", "Workflow message 2"]

    assert Enum.all?(received, &(&1.message.attributes == %{"type" => "test"}))

    ack_ids = Enum.map(received, & &1.ack_id)
    assert :ok = PubsubGrpc.acknowledge(@project, subscription_name, ack_ids)
  end

  test "with_connection using main API", %{topic_name: topic_name} do
    topic_path = "projects/#{@project}/topics/#{topic_name}"

    result =
      PubsubGrpc.with_connection(fn channel ->
        {:ok, auth_opts} = PubsubGrpc.Auth.request_opts(channel)
        PublisherStub.create_topic(channel, %PubsubV1.Topic{name: topic_path}, auth_opts)
      end)

    assert {:ok, %PubsubV1.Topic{name: ^topic_path}} = result
  end

  test "with_connection/execute return {:ok, value} for non-tuple callback results" do
    assert {:ok, :ok} = PubsubGrpc.with_connection(fn %GRPC.Channel{} -> :ok end)

    assert {:ok, %{answer: 42}} =
             PubsubGrpc.with_connection(fn %GRPC.Channel{} -> %{answer: 42} end)

    assert {:ok, :ok} = PubsubGrpc.execute(fn %GRPC.Channel{} -> :ok end)
  end

  test "execute maps a gRPC error to a structured error" do
    operation = fn channel ->
      request = %PubsubV1.GetTopicRequest{
        topic: "projects/#{@project}/topics/#{unique_name("non-existent")}"
      }

      PublisherStub.get_topic(channel, request)
    end

    assert {:error, %Error{code: :not_found}} = PubsubGrpc.execute(operation)
  end
end
