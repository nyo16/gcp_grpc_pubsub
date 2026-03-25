defmodule PubsubGrpc.ValidationTest do
  use ExUnit.Case, async: true

  alias PubsubGrpc.{Error, Validation}

  describe "validate_project_id/1" do
    test "accepts valid project ID" do
      assert {:ok, "my-project"} = Validation.validate_project_id("my-project")
    end

    test "rejects empty string" do
      assert {:error, %Error{code: :validation_error}} = Validation.validate_project_id("")
    end

    test "rejects nil" do
      assert {:error, %Error{code: :validation_error}} = Validation.validate_project_id(nil)
    end

    test "rejects non-string" do
      assert {:error, %Error{code: :validation_error}} = Validation.validate_project_id(123)
    end
  end

  describe "validate_topic_id/1" do
    test "accepts valid topic ID" do
      assert {:ok, "my-topic"} = Validation.validate_topic_id("my-topic")
    end

    test "rejects empty string" do
      assert {:error, %Error{code: :validation_error}} = Validation.validate_topic_id("")
    end

    test "rejects nil" do
      assert {:error, %Error{code: :validation_error}} = Validation.validate_topic_id(nil)
    end
  end

  describe "validate_subscription_id/1" do
    test "accepts valid subscription ID" do
      assert {:ok, "my-sub"} = Validation.validate_subscription_id("my-sub")
    end

    test "rejects empty string" do
      assert {:error, %Error{code: :validation_error}} = Validation.validate_subscription_id("")
    end
  end

  describe "validate_schema_id/1" do
    test "accepts valid schema ID" do
      assert {:ok, "my-schema"} = Validation.validate_schema_id("my-schema")
    end

    test "rejects empty string" do
      assert {:error, %Error{code: :validation_error}} = Validation.validate_schema_id("")
    end
  end

  describe "validate_messages/1" do
    test "accepts valid messages with data" do
      messages = [%{data: "hello"}]
      assert {:ok, ^messages} = Validation.validate_messages(messages)
    end

    test "accepts messages with attributes only" do
      messages = [%{attributes: %{"key" => "value"}}]
      assert {:ok, ^messages} = Validation.validate_messages(messages)
    end

    test "accepts messages with both data and attributes" do
      messages = [%{data: "hello", attributes: %{"key" => "value"}}]
      assert {:ok, ^messages} = Validation.validate_messages(messages)
    end

    test "rejects empty list" do
      assert {:error, %Error{code: :validation_error}} = Validation.validate_messages([])
    end

    test "rejects nil" do
      assert {:error, %Error{code: :validation_error}} = Validation.validate_messages(nil)
    end

    test "rejects messages without data or attributes" do
      assert {:error, %Error{code: :validation_error}} =
               Validation.validate_messages([%{foo: "bar"}])
    end

    test "rejects messages with empty attributes" do
      assert {:error, %Error{code: :validation_error}} =
               Validation.validate_messages([%{attributes: %{}}])
    end

    test "rejects non-binary data" do
      assert {:error, %Error{code: :validation_error}} =
               Validation.validate_messages([%{data: 123}])
    end
  end

  describe "validate_ack_ids/1" do
    test "accepts valid ack IDs" do
      ids = ["id1", "id2"]
      assert {:ok, ^ids} = Validation.validate_ack_ids(ids)
    end

    test "rejects empty list" do
      assert {:error, %Error{code: :validation_error}} = Validation.validate_ack_ids([])
    end

    test "rejects list with empty strings" do
      assert {:error, %Error{code: :validation_error}} = Validation.validate_ack_ids([""])
    end

    test "rejects nil" do
      assert {:error, %Error{code: :validation_error}} = Validation.validate_ack_ids(nil)
    end

    test "rejects list with non-strings" do
      assert {:error, %Error{code: :validation_error}} = Validation.validate_ack_ids([123])
    end
  end

  describe "validate_ack_deadline/1" do
    test "accepts 10 (minimum)" do
      assert {:ok, 10} = Validation.validate_ack_deadline(10)
    end

    test "accepts 600 (maximum)" do
      assert {:ok, 600} = Validation.validate_ack_deadline(600)
    end

    test "accepts value in range" do
      assert {:ok, 60} = Validation.validate_ack_deadline(60)
    end

    test "rejects 9 (below minimum)" do
      assert {:error, %Error{code: :validation_error}} = Validation.validate_ack_deadline(9)
    end

    test "rejects 601 (above maximum)" do
      assert {:error, %Error{code: :validation_error}} = Validation.validate_ack_deadline(601)
    end

    test "rejects non-integer" do
      assert {:error, %Error{code: :validation_error}} = Validation.validate_ack_deadline("60")
    end
  end

  describe "validate_ack_deadline_with_zero/1" do
    test "accepts 0 (for nack)" do
      assert {:ok, 0} = Validation.validate_ack_deadline_with_zero(0)
    end

    test "accepts 600 (maximum)" do
      assert {:ok, 600} = Validation.validate_ack_deadline_with_zero(600)
    end

    test "rejects negative" do
      assert {:error, %Error{code: :validation_error}} =
               Validation.validate_ack_deadline_with_zero(-1)
    end
  end

  describe "validate_max_messages/1" do
    test "accepts positive integer" do
      assert {:ok, 10} = Validation.validate_max_messages(10)
    end

    test "accepts 1" do
      assert {:ok, 1} = Validation.validate_max_messages(1)
    end

    test "rejects 0" do
      assert {:error, %Error{code: :validation_error}} = Validation.validate_max_messages(0)
    end

    test "rejects negative" do
      assert {:error, %Error{code: :validation_error}} = Validation.validate_max_messages(-1)
    end
  end

  describe "validate_schema_type/1" do
    test "accepts :protocol_buffer" do
      assert {:ok, :PROTOCOL_BUFFER} = Validation.validate_schema_type(:protocol_buffer)
    end

    test "accepts :avro" do
      assert {:ok, :AVRO} = Validation.validate_schema_type(:avro)
    end

    test "rejects invalid type" do
      assert {:error, %Error{code: :validation_error}} = Validation.validate_schema_type(:json)
    end

    test "rejects string" do
      assert {:error, %Error{code: :validation_error}} =
               Validation.validate_schema_type("protocol_buffer")
    end
  end

  describe "validate_schema_view/1" do
    test "accepts :basic" do
      assert {:ok, :BASIC} = Validation.validate_schema_view(:basic)
    end

    test "accepts :full" do
      assert {:ok, :FULL} = Validation.validate_schema_view(:full)
    end

    test "rejects invalid view" do
      assert {:error, %Error{code: :validation_error}} =
               Validation.validate_schema_view(:summary)
    end
  end

  describe "validate_encoding/1" do
    test "accepts :json" do
      assert {:ok, :JSON} = Validation.validate_encoding(:json)
    end

    test "accepts :binary" do
      assert {:ok, :BINARY} = Validation.validate_encoding(:binary)
    end

    test "rejects invalid encoding" do
      assert {:error, %Error{code: :validation_error}} = Validation.validate_encoding(:xml)
    end
  end
end
