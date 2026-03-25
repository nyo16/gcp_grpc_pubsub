defmodule PubsubGrpc.ValidationIntegrationTest do
  @moduledoc """
  Tests that the public API properly rejects invalid inputs before
  making network calls. These tests do NOT require the emulator.
  """
  use ExUnit.Case, async: true

  alias PubsubGrpc.Error

  describe "create_topic/2 validation" do
    test "rejects empty project_id" do
      assert {:error, %Error{code: :validation_error}} = PubsubGrpc.create_topic("", "topic")
    end

    test "rejects empty topic_id" do
      assert {:error, %Error{code: :validation_error}} = PubsubGrpc.create_topic("proj", "")
    end

    test "rejects nil project_id" do
      assert {:error, %Error{code: :validation_error}} = PubsubGrpc.create_topic(nil, "topic")
    end
  end

  describe "get_topic/2 validation" do
    test "rejects empty project_id" do
      assert {:error, %Error{code: :validation_error}} = PubsubGrpc.get_topic("", "topic")
    end

    test "rejects empty topic_id" do
      assert {:error, %Error{code: :validation_error}} = PubsubGrpc.get_topic("proj", "")
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
               PubsubGrpc.publish("proj", "topic", [])
    end

    test "rejects messages without data or attributes" do
      assert {:error, %Error{code: :validation_error}} =
               PubsubGrpc.publish("proj", "topic", [%{foo: "bar"}])
    end
  end

  describe "create_subscription/4 validation" do
    test "rejects empty subscription_id" do
      assert {:error, %Error{code: :validation_error}} =
               PubsubGrpc.create_subscription("proj", "topic", "")
    end

    test "rejects ack_deadline below minimum" do
      assert {:error, %Error{code: :validation_error}} =
               PubsubGrpc.create_subscription("proj", "topic", "sub", ack_deadline_seconds: 5)
    end

    test "rejects ack_deadline above maximum" do
      assert {:error, %Error{code: :validation_error}} =
               PubsubGrpc.create_subscription("proj", "topic", "sub", ack_deadline_seconds: 700)
    end
  end

  describe "get_subscription/2 validation" do
    test "rejects empty subscription_id" do
      assert {:error, %Error{code: :validation_error}} =
               PubsubGrpc.get_subscription("proj", "")
    end
  end

  describe "delete_subscription/2 validation" do
    test "rejects empty subscription_id" do
      assert {:error, %Error{code: :validation_error}} =
               PubsubGrpc.delete_subscription("proj", "")
    end
  end

  describe "list_subscriptions/2 validation" do
    test "rejects empty project_id" do
      assert {:error, %Error{code: :validation_error}} = PubsubGrpc.list_subscriptions("")
    end
  end

  describe "pull/3 validation" do
    test "rejects zero max_messages" do
      assert {:error, %Error{code: :validation_error}} = PubsubGrpc.pull("proj", "sub", 0)
    end

    test "rejects negative max_messages" do
      assert {:error, %Error{code: :validation_error}} = PubsubGrpc.pull("proj", "sub", -1)
    end
  end

  describe "acknowledge/3 validation" do
    test "rejects empty ack_ids list" do
      assert {:error, %Error{code: :validation_error}} =
               PubsubGrpc.acknowledge("proj", "sub", [])
    end

    test "rejects nil ack_ids" do
      assert {:error, %Error{code: :validation_error}} =
               PubsubGrpc.acknowledge("proj", "sub", nil)
    end
  end

  describe "modify_ack_deadline/4 validation" do
    test "rejects empty ack_ids" do
      assert {:error, %Error{code: :validation_error}} =
               PubsubGrpc.modify_ack_deadline("proj", "sub", [], 30)
    end

    test "rejects negative deadline" do
      assert {:error, %Error{code: :validation_error}} =
               PubsubGrpc.modify_ack_deadline("proj", "sub", ["id"], -1)
    end

    test "accepts zero deadline (nack)" do
      # Should pass validation but fail at network level
      # (we just check it doesn't return a validation error)
      result = PubsubGrpc.modify_ack_deadline("proj", "sub", ["id"], 0)
      refute match?({:error, %Error{code: :validation_error}}, result)
    end
  end

  describe "nack/3 validation" do
    test "rejects empty ack_ids" do
      assert {:error, %Error{code: :validation_error}} = PubsubGrpc.nack("proj", "sub", [])
    end
  end

  describe "schema validation" do
    test "create_schema rejects invalid type" do
      assert {:error, %Error{code: :validation_error}} =
               PubsubGrpc.create_schema("proj", "schema", :invalid, "def")
    end

    test "validate_schema rejects invalid type" do
      assert {:error, %Error{code: :validation_error}} =
               PubsubGrpc.validate_schema("proj", :invalid, "def")
    end

    test "get_schema rejects empty schema_id" do
      assert {:error, %Error{code: :validation_error}} = PubsubGrpc.get_schema("proj", "")
    end

    test "list_schemas rejects empty project_id" do
      assert {:error, %Error{code: :validation_error}} = PubsubGrpc.list_schemas("")
    end

    test "validate_message rejects invalid encoding" do
      assert {:error, %Error{code: :validation_error}} =
               PubsubGrpc.validate_message("proj", "schema", "msg", :invalid)
    end

    test "validate_message_with_schema rejects invalid type" do
      assert {:error, %Error{code: :validation_error}} =
               PubsubGrpc.validate_message_with_schema("proj", :invalid, "def", "msg", :json)
    end

    test "validate_message_with_schema rejects invalid encoding" do
      assert {:error, %Error{code: :validation_error}} =
               PubsubGrpc.validate_message_with_schema(
                 "proj",
                 :protocol_buffer,
                 "def",
                 "msg",
                 :invalid
               )
    end
  end
end
