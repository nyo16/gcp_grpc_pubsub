defmodule PubsubGrpc.ValidationTest do
  use ExUnit.Case, async: true

  alias Google.Pubsub.V1.PubsubMessage
  alias PubsubGrpc.{Error, Validation}

  describe "validate_project_id/1" do
    test "accepts project IDs, project numbers and domain-scoped IDs" do
      for id <- [
            "my-project",
            "test-project-id",
            "abcdef",
            "a23456789012345678901234567890",
            "project-123",
            "123456789012",
            "example.com:my-project",
            "sub.example.co.uk:legacy-app"
          ] do
        assert {:ok, ^id} = Validation.validate_project_id(id)
      end
    end

    test "rejects malformed project IDs" do
      for id <- [
            "",
            "proj",
            "abcde",
            "a234567890123456789012345678901",
            "1project",
            "-project",
            "my-project-",
            "My-Project",
            "my_project",
            "my project",
            "my.project",
            "example.com:",
            ":my-project",
            "example:my-project",
            "example.com:my-project-",
            "projects/my-project",
            "12345678901234567890"
          ] do
        assert {:error, %Error{code: :validation_error}} = Validation.validate_project_id(id),
               "expected #{inspect(id)} to be rejected"
      end
    end

    test "rejects nil" do
      assert {:error, %Error{code: :validation_error}} = Validation.validate_project_id(nil)
    end

    test "rejects non-string" do
      assert {:error, %Error{code: :validation_error}} = Validation.validate_project_id(123)
    end
  end

  describe "validate_schema_name/1" do
    test "accepts a schema ID or a full schema name" do
      assert {:ok, "my-schema"} = Validation.validate_schema_name("my-schema")

      assert {:ok, "projects/my-project/schemas/my-schema"} =
               Validation.validate_schema_name("projects/my-project/schemas/my-schema")
    end

    test "rejects anything else" do
      for name <- [
            "",
            "projects/my-project/topics/my-schema",
            "projects/proj/schemas/my-schema",
            "projects/my-project/schemas/",
            "my-project/schemas/my-schema",
            nil
          ] do
        assert {:error, %Error{code: :validation_error}} = Validation.validate_schema_name(name)
      end
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

    test "rejects names starting with digit" do
      assert {:error, %Error{code: :validation_error}} = Validation.validate_topic_id("1topic")
    end

    test "rejects names with disallowed characters" do
      assert {:error, %Error{code: :validation_error}} = Validation.validate_topic_id("bad/name")
    end

    test "rejects names below minimum length (3 chars)" do
      assert {:error, %Error{code: :validation_error}} = Validation.validate_topic_id("ab")
    end

    test "rejects names exceeding 255 chars" do
      long = "a" <> String.duplicate("b", 255)
      assert {:error, %Error{code: :validation_error}} = Validation.validate_topic_id(long)
    end

    test "rejects reserved 'goog' prefix" do
      assert {:error, %Error{code: :validation_error}} = Validation.validate_topic_id("googlike")
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

  describe "build_publish_messages/1" do
    test "accepts messages with data, attributes, or both and builds PubsubMessages" do
      messages = [
        %{data: "hello"},
        %{attributes: %{"key" => "value"}},
        %{data: "hi", attributes: %{"k" => "v"}},
        %{data: "", attributes: %{"k" => "v"}}
      ]

      assert {:ok, built, 4} = Validation.build_publish_messages(messages)

      assert [
               %PubsubMessage{data: "hello", attributes: %{}},
               %PubsubMessage{data: "", attributes: %{"key" => "value"}},
               %PubsubMessage{data: "hi", attributes: %{"k" => "v"}},
               %PubsubMessage{data: "", attributes: %{"k" => "v"}}
             ] = built
    end

    test "rejects an empty list or a non-list" do
      assert {:error, %Error{code: :validation_error}} = Validation.build_publish_messages([])
      assert {:error, %Error{code: :validation_error}} = Validation.build_publish_messages(nil)
    end

    test "rejects invalid messages" do
      for message <- [
            %{foo: "bar"},
            %{attributes: %{}},
            %{data: 123},
            %{data: ""},
            %{data: "", attributes: %{}},
            %{data: "x", attributes: [{"k", "v"}]},
            %{data: 123, attributes: %{"k" => "v"}},
            "not a map"
          ] do
        assert {:error, %Error{code: :validation_error}} =
                 Validation.build_publish_messages([%{data: "ok"}, message]),
               "expected #{inspect(message)} to be rejected"
      end
    end

    test "accepts exactly the message-count limit and rejects one more" do
      limit = Validation.max_publish_messages()

      assert {:ok, _, ^limit} =
               Validation.build_publish_messages(List.duplicate(%{data: "x"}, limit))

      assert {:error, %Error{code: :validation_error, message: message}} =
               Validation.build_publish_messages(List.duplicate(%{data: "x"}, limit + 1))

      assert message =~ "#{limit} messages"
    end

    test "accepts exactly the byte limit (data + attribute keys/values) and rejects one more" do
      limit = Validation.max_publish_bytes()
      attributes = %{"key" => "value"}
      data = String.duplicate("x", limit - byte_size("key") - byte_size("value"))

      assert {:ok, [_], 1} =
               Validation.build_publish_messages([%{data: data, attributes: attributes}])

      assert {:error, %Error{code: :validation_error, message: message}} =
               Validation.build_publish_messages([
                 %{data: data, attributes: attributes},
                 %{data: "y"}
               ])

      assert message =~ "#{limit}-byte"
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

    test "accepts exactly the request-size limit and rejects one more byte" do
      limit = Validation.max_ack_request_bytes()
      at_limit = [String.duplicate("a", limit - 1), "b"]

      assert {:ok, ^at_limit} = Validation.validate_ack_ids(at_limit)

      assert {:error, %Error{code: :validation_error, message: message}} =
               Validation.validate_ack_ids(at_limit ++ ["c"])

      assert message =~ "#{limit}-byte"
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

    test "accepts the int32 maximum and rejects one more" do
      assert {:ok, 2_147_483_647} = Validation.validate_max_messages(2_147_483_647)

      assert {:error, %Error{code: :validation_error}} =
               Validation.validate_max_messages(2_147_483_648)
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
