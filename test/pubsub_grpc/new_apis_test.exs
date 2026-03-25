defmodule PubsubGrpc.NewApisTest do
  @moduledoc """
  Integration tests for new APIs added in v0.4.0:
  get_topic, get_subscription, list_subscriptions, modify_ack_deadline, nack
  """
  use ExUnit.Case

  alias PubsubGrpc.EmulatorHelper

  @moduletag :integration

  setup do
    topic_name = EmulatorHelper.test_topic_name()
    subscription_name = EmulatorHelper.test_subscription_name()

    on_exit(fn ->
      EmulatorHelper.cleanup_subscription(subscription_name)
      EmulatorHelper.cleanup_topic(topic_name)
    end)

    %{topic_name: topic_name, subscription_name: subscription_name}
  end

  describe "get_topic/2" do
    test "returns topic that exists", %{topic_name: topic_name} do
      {:ok, _} = PubsubGrpc.create_topic("test-project-id", topic_name)

      assert {:ok, topic} = PubsubGrpc.get_topic("test-project-id", topic_name)
      assert topic.name == "projects/test-project-id/topics/#{topic_name}"
    end

    test "returns not_found for non-existent topic" do
      ts = System.monotonic_time()

      assert {:error, %PubsubGrpc.Error{code: :not_found}} =
               PubsubGrpc.get_topic("test-project-id", "non-existent-#{ts}")
    end
  end

  describe "get_subscription/2" do
    test "returns subscription that exists", %{
      topic_name: topic_name,
      subscription_name: subscription_name
    } do
      {:ok, _} = PubsubGrpc.create_topic("test-project-id", topic_name)
      {:ok, _} = PubsubGrpc.create_subscription("test-project-id", topic_name, subscription_name)

      assert {:ok, sub} = PubsubGrpc.get_subscription("test-project-id", subscription_name)
      assert sub.name == "projects/test-project-id/subscriptions/#{subscription_name}"
    end

    test "returns not_found for non-existent subscription" do
      ts = System.monotonic_time()

      assert {:error, %PubsubGrpc.Error{code: :not_found}} =
               PubsubGrpc.get_subscription("test-project-id", "non-existent-#{ts}")
    end
  end

  describe "list_subscriptions/2" do
    test "lists subscriptions in project", %{
      topic_name: topic_name,
      subscription_name: subscription_name
    } do
      {:ok, _} = PubsubGrpc.create_topic("test-project-id", topic_name)
      {:ok, _} = PubsubGrpc.create_subscription("test-project-id", topic_name, subscription_name)

      assert {:ok, result} = PubsubGrpc.list_subscriptions("test-project-id")
      sub_names = Enum.map(result.subscriptions, & &1.name)

      assert "projects/test-project-id/subscriptions/#{subscription_name}" in sub_names
    end
  end

  describe "modify_ack_deadline/4" do
    test "modifies ack deadline for pulled messages", %{
      topic_name: topic_name,
      subscription_name: subscription_name
    } do
      {:ok, _} = PubsubGrpc.create_topic("test-project-id", topic_name)
      {:ok, _} = PubsubGrpc.create_subscription("test-project-id", topic_name, subscription_name)
      {:ok, _} = PubsubGrpc.publish_message("test-project-id", topic_name, "test message")

      messages = pull_with_retry("test-project-id", subscription_name, 5)
      assert messages != []

      ack_ids = Enum.map(messages, & &1.ack_id)

      assert :ok =
               PubsubGrpc.modify_ack_deadline("test-project-id", subscription_name, ack_ids, 30)

      :ok = PubsubGrpc.acknowledge("test-project-id", subscription_name, ack_ids)
    end
  end

  describe "nack/3" do
    test "nacks messages for redelivery", %{
      topic_name: topic_name,
      subscription_name: subscription_name
    } do
      {:ok, _} = PubsubGrpc.create_topic("test-project-id", topic_name)

      {:ok, _} =
        PubsubGrpc.create_subscription("test-project-id", topic_name, subscription_name,
          ack_deadline_seconds: 10
        )

      {:ok, _} = PubsubGrpc.publish_message("test-project-id", topic_name, "nack test")

      messages = pull_with_retry("test-project-id", subscription_name, 5)
      assert messages != []

      ack_ids = Enum.map(messages, & &1.ack_id)

      assert :ok = PubsubGrpc.nack("test-project-id", subscription_name, ack_ids)

      # Message should be redelivered
      redelivered = pull_with_retry("test-project-id", subscription_name, 10)
      assert redelivered != []

      new_ack_ids = Enum.map(redelivered, & &1.ack_id)
      PubsubGrpc.acknowledge("test-project-id", subscription_name, new_ack_ids)
    end
  end

  defp pull_with_retry(project, sub, attempts) do
    Enum.reduce_while(1..attempts, [], &pull_attempt(project, sub, &1, &2))
  end

  defp pull_attempt(project, sub, _attempt, acc) do
    case PubsubGrpc.pull(project, sub, 10) do
      {:ok, []} when acc == [] ->
        :timer.sleep(500)
        {:cont, acc}

      {:ok, msgs} ->
        all = acc ++ msgs
        if all != [], do: {:halt, all}, else: {:cont, all}

      {:error, _} ->
        :timer.sleep(500)
        {:cont, acc}
    end
  end
end
