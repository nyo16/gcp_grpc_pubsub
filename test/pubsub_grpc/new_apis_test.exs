defmodule PubsubGrpc.NewApisTest do
  @moduledoc """
  Integration tests for the APIs added in v0.4.0:
  get_topic, get_subscription, list_subscriptions, modify_ack_deadline, nack
  """
  use ExUnit.Case, async: true

  import PubsubGrpc.EmulatorHelper, only: [unique_resources: 1, unique_name: 1, list_all: 2]
  import PubsubGrpc.Eventually, only: [pull_until: 3]

  alias PubsubGrpc.Error

  @moduletag :integration

  @project "test-project-id"

  setup :unique_resources

  describe "get_topic/2" do
    test "returns topic that exists", %{topic_name: topic_name} do
      {:ok, _} = PubsubGrpc.create_topic(@project, topic_name)

      assert {:ok, topic} = PubsubGrpc.get_topic(@project, topic_name)
      assert topic.name == "projects/#{@project}/topics/#{topic_name}"
    end

    test "returns not_found for non-existent topic" do
      assert {:error, %Error{code: :not_found}} =
               PubsubGrpc.get_topic(@project, unique_name("non-existent"))
    end
  end

  describe "get_subscription/2" do
    test "returns subscription that exists", %{
      topic_name: topic_name,
      subscription_name: subscription_name
    } do
      {:ok, _} = PubsubGrpc.create_topic(@project, topic_name)
      {:ok, _} = PubsubGrpc.create_subscription(@project, topic_name, subscription_name)

      assert {:ok, sub} = PubsubGrpc.get_subscription(@project, subscription_name)
      assert sub.name == "projects/#{@project}/subscriptions/#{subscription_name}"
    end

    test "returns not_found for non-existent subscription" do
      assert {:error, %Error{code: :not_found}} =
               PubsubGrpc.get_subscription(@project, unique_name("non-existent"))
    end
  end

  describe "list_subscriptions/2" do
    test "lists subscriptions in project", %{
      topic_name: topic_name,
      subscription_name: subscription_name
    } do
      {:ok, _} = PubsubGrpc.create_topic(@project, topic_name)
      {:ok, _} = PubsubGrpc.create_subscription(@project, topic_name, subscription_name)

      subscriptions = list_all(:subscriptions, &PubsubGrpc.list_subscriptions(@project, &1))

      assert "projects/#{@project}/subscriptions/#{subscription_name}" in Enum.map(
               subscriptions,
               & &1.name
             )
    end

    test "pages with page_size and page_token", %{topic_name: topic_name} do
      {:ok, _} = PubsubGrpc.create_topic(@project, topic_name)

      for _ <- 1..2 do
        sub = PubsubGrpc.EmulatorHelper.track_subscription(unique_name("test-subscription"))
        {:ok, _} = PubsubGrpc.create_subscription(@project, topic_name, sub)
      end

      assert {:ok, %{subscriptions: [first], next_page_token: token}} =
               PubsubGrpc.list_subscriptions(@project, page_size: 1)

      assert token != ""

      assert {:ok, %{subscriptions: [second]}} =
               PubsubGrpc.list_subscriptions(@project, page_size: 1, page_token: token)

      assert first.name != second.name
    end
  end

  describe "modify_ack_deadline/4" do
    test "a zero deadline releases only the given messages for redelivery", %{
      topic_name: topic_name,
      subscription_name: subscription_name
    } do
      {:ok, _} = PubsubGrpc.create_topic(@project, topic_name)

      {:ok, _} =
        PubsubGrpc.create_subscription(@project, topic_name, subscription_name,
          ack_deadline_seconds: 60
        )

      {:ok, _} = PubsubGrpc.publish(@project, topic_name, [%{data: "reset"}, %{data: "kept"}])

      by_data =
        @project |> pull_until(subscription_name, 2) |> Map.new(&{&1.message.data, &1})

      reset = by_data["reset"]
      kept = by_data["kept"]

      assert :ok =
               PubsubGrpc.modify_ack_deadline(@project, subscription_name, [reset.ack_id], 0)

      # "kept" stays leased for 60 s, so only "reset" comes back.
      assert [redelivered] = pull_until(@project, subscription_name, 1)
      assert redelivered.message.message_id == reset.message.message_id

      assert :ok =
               PubsubGrpc.acknowledge(@project, subscription_name, [
                 redelivered.ack_id,
                 kept.ack_id
               ])
    end
  end

  describe "nack/3" do
    test "nacks messages for redelivery", %{
      topic_name: topic_name,
      subscription_name: subscription_name
    } do
      {:ok, _} = PubsubGrpc.create_topic(@project, topic_name)

      {:ok, _} =
        PubsubGrpc.create_subscription(@project, topic_name, subscription_name,
          ack_deadline_seconds: 10
        )

      {:ok, %{message_ids: [message_id]}} =
        PubsubGrpc.publish_message(@project, topic_name, "nack test")

      [first] = pull_until(@project, subscription_name, 1)
      assert first.message.message_id == message_id

      assert :ok = PubsubGrpc.nack(@project, subscription_name, [first.ack_id])

      # The nacked message is redelivered.
      [redelivered] = pull_until(@project, subscription_name, 1)
      assert redelivered.message.message_id == message_id
      assert :ok = PubsubGrpc.acknowledge(@project, subscription_name, [redelivered.ack_id])
    end
  end
end
