defmodule PubsubGrpc.ApiValidationTest do
  @moduledoc """
  Tests that the public API properly rejects invalid inputs before
  making network calls. These tests do NOT require the emulator.
  """
  use ExUnit.Case, async: true

  alias PubsubGrpc.{Error, Validation}

  @project "my-project"

  describe "create_topic/2 validation" do
    test "rejects empty project_id" do
      assert {:error, %Error{code: :validation_error}} = PubsubGrpc.create_topic("", "topic")
    end

    test "rejects empty topic_id" do
      assert {:error, %Error{code: :validation_error}} = PubsubGrpc.create_topic(@project, "")
    end

    test "rejects nil project_id" do
      assert {:error, %Error{code: :validation_error}} = PubsubGrpc.create_topic(nil, "topic")
    end

    test "rejects a malformed project_id" do
      assert {:error, %Error{code: :validation_error, message: message}} =
               PubsubGrpc.create_topic("My_Project", "topic")

      assert message =~ "project_id"
    end
  end

  describe "get_topic/2 validation" do
    test "rejects empty project_id" do
      assert {:error, %Error{code: :validation_error}} = PubsubGrpc.get_topic("", "topic")
    end

    test "rejects empty topic_id" do
      assert {:error, %Error{code: :validation_error}} = PubsubGrpc.get_topic(@project, "")
    end
  end

  describe "delete_topic/2 validation" do
    test "rejects empty project_id" do
      assert {:error, %Error{code: :validation_error}} = PubsubGrpc.delete_topic("", "topic")
    end
  end

  describe "list_topics/2 validation" do
    test "rejects empty project_id" do
      assert {:error, %Error{code: :validation_error}} = PubsubGrpc.list_topics("")
    end
  end

  describe "publish/3 validation" do
    test "rejects empty project_id" do
      assert {:error, %Error{code: :validation_error}} =
               PubsubGrpc.publish("", "topic", [%{data: "hi"}])
    end

    test "rejects empty messages list" do
      assert {:error, %Error{code: :validation_error}} =
               PubsubGrpc.publish(@project, "topic", [])
    end

    test "rejects messages without data or attributes" do
      assert {:error, %Error{code: :validation_error}} =
               PubsubGrpc.publish(@project, "topic", [%{foo: "bar"}])
    end

    test "rejects more messages than the publish limit" do
      messages = List.duplicate(%{data: "x"}, Validation.max_publish_messages() + 1)

      assert {:error, %Error{code: :validation_error, message: message}} =
               PubsubGrpc.publish(@project, "topic", messages)

      assert message =~ "at most 1000 messages"
    end
  end

  describe "publish_message/3,4,5" do
    test "rejects non-map attributes that are not options" do
      assert {:error, %Error{code: :validation_error}} =
               PubsubGrpc.publish_message(@project, "topic", "data", "not-a-map")
    end
  end

  describe "create_subscription/4 validation" do
    test "rejects empty subscription_id" do
      assert {:error, %Error{code: :validation_error}} =
               PubsubGrpc.create_subscription(@project, "topic", "")
    end

    test "rejects ack_deadline below minimum" do
      assert {:error, %Error{code: :validation_error}} =
               PubsubGrpc.create_subscription(@project, "topic", "sub", ack_deadline_seconds: 5)
    end

    test "rejects ack_deadline above maximum" do
      assert {:error, %Error{code: :validation_error}} =
               PubsubGrpc.create_subscription(@project, "topic", "sub", ack_deadline_seconds: 700)
    end
  end

  describe "get_subscription/2 validation" do
    test "rejects empty subscription_id" do
      assert {:error, %Error{code: :validation_error}} =
               PubsubGrpc.get_subscription(@project, "")
    end
  end

  describe "delete_subscription/2 validation" do
    test "rejects empty subscription_id" do
      assert {:error, %Error{code: :validation_error}} =
               PubsubGrpc.delete_subscription(@project, "")
    end
  end

  describe "list_subscriptions/2 validation" do
    test "rejects empty project_id" do
      assert {:error, %Error{code: :validation_error}} = PubsubGrpc.list_subscriptions("")
    end
  end

  describe "pull/3 validation" do
    test "rejects zero max_messages" do
      assert {:error, %Error{code: :validation_error}} = PubsubGrpc.pull(@project, "sub", 0)
    end

    test "rejects negative max_messages" do
      assert {:error, %Error{code: :validation_error}} = PubsubGrpc.pull(@project, "sub", -1)
    end
  end

  describe "acknowledge/3 validation" do
    test "rejects empty ack_ids list" do
      assert {:error, %Error{code: :validation_error}} =
               PubsubGrpc.acknowledge(@project, "sub", [])
    end

    test "rejects nil ack_ids" do
      assert {:error, %Error{code: :validation_error}} =
               PubsubGrpc.acknowledge(@project, "sub", nil)
    end
  end

  describe "modify_ack_deadline/4 validation" do
    test "rejects empty ack_ids" do
      assert {:error, %Error{code: :validation_error}} =
               PubsubGrpc.modify_ack_deadline(@project, "sub", [], 30)
    end

    test "rejects negative deadline" do
      assert {:error, %Error{code: :validation_error}} =
               PubsubGrpc.modify_ack_deadline(@project, "sub", ["id"], -1)
    end

    test "accepts zero deadline (nack)" do
      # Passes validation; with no pool to reach it fails at the connection level.
      assert {:error, %Error{code: :connection_error}} =
               PubsubGrpc.modify_ack_deadline(@project, "sub", ["id"], 0,
                 pool: :pubsub_grpc_no_such_pool
               )
    end
  end

  describe "nack/3 validation" do
    test "rejects empty ack_ids" do
      assert {:error, %Error{code: :validation_error}} = PubsubGrpc.nack(@project, "sub", [])
    end
  end

  describe "schema validation" do
    test "create_schema rejects invalid type" do
      assert {:error, %Error{code: :validation_error}} =
               PubsubGrpc.create_schema(@project, "schema", :invalid, "def")
    end

    test "validate_schema rejects invalid type" do
      assert {:error, %Error{code: :validation_error}} =
               PubsubGrpc.validate_schema(@project, :invalid, "def")
    end

    test "get_schema rejects empty schema_id" do
      assert {:error, %Error{code: :validation_error}} = PubsubGrpc.get_schema(@project, "")
    end

    test "list_schemas rejects empty project_id" do
      assert {:error, %Error{code: :validation_error}} = PubsubGrpc.list_schemas("")
    end

    test "validate_message rejects invalid encoding" do
      assert {:error, %Error{code: :validation_error}} =
               PubsubGrpc.validate_message(@project, "schema", "msg", :invalid)
    end

    test "validate_message rejects a malformed schema_name" do
      for name <- ["projects/my-project/topics/schema", "projects/P!/schemas/schema", "a/b", 42] do
        assert {:error, %Error{code: :validation_error}} =
                 PubsubGrpc.validate_message(@project, name, "msg", :json)
      end
    end

    test "validate_message_with_schema rejects invalid type" do
      assert {:error, %Error{code: :validation_error}} =
               PubsubGrpc.validate_message_with_schema(@project, :invalid, "def", "msg", :json)
    end

    test "validate_message_with_schema rejects invalid encoding" do
      assert {:error, %Error{code: :validation_error}} =
               PubsubGrpc.validate_message_with_schema(
                 @project,
                 :protocol_buffer,
                 "def",
                 "msg",
                 :invalid
               )
    end
  end
end
