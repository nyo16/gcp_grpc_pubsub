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

  # Every public operation, as a function of its `opts`. Valid arguments
  # otherwise, so only the options can fail validation.
  defp operations do
    [
      create_topic: &PubsubGrpc.create_topic(@project, "topic", &1),
      get_topic: &PubsubGrpc.get_topic(@project, "topic", &1),
      delete_topic: &PubsubGrpc.delete_topic(@project, "topic", &1),
      list_topics: &PubsubGrpc.list_topics(@project, &1),
      publish: &PubsubGrpc.publish(@project, "topic", [%{data: "x"}], &1),
      publish_message: &PubsubGrpc.publish_message(@project, "topic", "x", %{}, &1),
      create_subscription: &PubsubGrpc.create_subscription(@project, "topic", "sub", &1),
      get_subscription: &PubsubGrpc.get_subscription(@project, "sub", &1),
      delete_subscription: &PubsubGrpc.delete_subscription(@project, "sub", &1),
      list_subscriptions: &PubsubGrpc.list_subscriptions(@project, &1),
      pull: &PubsubGrpc.pull(@project, "sub", 5, &1),
      acknowledge: &PubsubGrpc.acknowledge(@project, "sub", ["ack"], &1),
      modify_ack_deadline: &PubsubGrpc.modify_ack_deadline(@project, "sub", ["ack"], 30, &1),
      nack: &PubsubGrpc.nack(@project, "sub", ["ack"], &1),
      list_schemas: &PubsubGrpc.list_schemas(@project, &1),
      get_schema: &PubsubGrpc.get_schema(@project, "schema", &1),
      create_schema: &PubsubGrpc.create_schema(@project, "schema", :avro, "{}", &1),
      delete_schema: &PubsubGrpc.delete_schema(@project, "schema", &1),
      validate_schema: &PubsubGrpc.validate_schema(@project, :avro, "{}", &1),
      list_schema_revisions: &PubsubGrpc.list_schema_revisions(@project, "schema", &1),
      validate_message: &PubsubGrpc.validate_message(@project, "schema", "{}", :json, &1),
      validate_message_with_schema:
        &PubsubGrpc.validate_message_with_schema(@project, :avro, "{}", "{}", :json, &1),
      execute: &PubsubGrpc.execute(fn _channel -> flunk("callback must not run") end, &1)
    ]
  end

  @list_operations [:list_topics, :list_subscriptions, :list_schemas, :list_schema_revisions]

  describe "per-call options" do
    test "invalid common options are rejected by every operation, before checkout" do
      for {name, call} <- operations(),
          {opts, message} <- [
            {[timeout: "5s"], "timeout must be"},
            {[timeout: 0], "timeout must be"},
            {[timeout: -1], "timeout must be"},
            {%{timeout: 5_000}, "opts must be a keyword list"},
            {[:timeout], "opts must be a keyword list"}
          ] do
        assert {:error, %Error{code: :validation_error, message: actual}} = call.(opts),
               "#{name} with #{inspect(opts)}"

        assert actual =~ message, "#{name} with #{inspect(opts)}: #{actual}"
      end
    end

    test "an unknown key is rejected and named, e.g. a typo for ack_deadline_seconds" do
      for {name, call} <- operations() do
        assert {:error, %Error{code: :validation_error, message: message}} =
                 call.(ack_deadline: 30),
               "#{name}"

        assert message =~ "unknown option(s) [:ack_deadline]"
      end
    end

    test "invalid paging options are rejected by list operations" do
      for name <- @list_operations,
          {opts, message} <- [
            {[page_size: "10"], "page_size must be"},
            {[page_size: -1], "page_size must be"},
            {[page_size: 2_147_483_648], "page_size must be"},
            {[page_token: 123], "page_token must be a string"}
          ] do
        assert {:error, %Error{code: :validation_error, message: actual}} =
                 operations()[name].(opts),
               "#{name} with #{inspect(opts)}"

        assert actual =~ message
      end
    end

    test "paging options are only accepted by list operations" do
      for {name, call} <- operations(), name not in @list_operations do
        assert {:error, %Error{code: :validation_error, message: message}} =
                 call.(page_size: 10),
               "#{name}"

        assert message =~ "unknown option(s) [:page_size]"
      end
    end

    # Valid options pass validation and reach the pool, which does not exist here.
    test "valid options pass validation" do
      opts = [pool: :pubsub_grpc_no_such_pool, timeout: :infinity]

      assert {:error, %Error{code: :connection_error}} =
               PubsubGrpc.list_topics(@project, [page_size: 10, page_token: "t"] ++ opts)

      assert {:error, %Error{code: :connection_error}} =
               PubsubGrpc.create_subscription(
                 @project,
                 "topic",
                 "sub",
                 [ack_deadline_seconds: 30] ++ opts
               )

      assert {:error, %Error{code: :connection_error}} =
               PubsubGrpc.get_schema(@project, "schema", [view: :basic, timeout: nil] ++ opts)

      # nil paging values mean the default, as before options were validated.
      assert {:error, %Error{code: :connection_error}} =
               PubsubGrpc.list_topics(@project, [page_size: nil, page_token: nil] ++ opts)
    end

    test "duplicate keys are allowed and the first one wins" do
      # The first :pool (nonexistent) is used; the second would be the real pool.
      assert {:error, %Error{code: :connection_error}} =
               PubsubGrpc.get_topic(@project, "topic",
                 pool: :pubsub_grpc_no_such_pool,
                 pool: PubsubGrpc.ConnectionPool
               )

      assert {:error, %Error{code: :validation_error, message: "timeout must be" <> _}} =
               PubsubGrpc.get_topic(@project, "topic", timeout: "5s", timeout: 1_000)
    end

    test "a :pool that is not an atom is rejected by every operation" do
      for {name, call} <- operations(), pool <- ["MyPool", 42, %{}, self()] do
        assert {:error, %Error{code: :validation_error, message: "pool must be" <> _}} =
                 call.(pool: pool),
               "#{name} with pool: #{inspect(pool)}"
      end
    end
  end

  describe "argument types that used to raise" do
    test "a non-binary schema definition or message is a validation error" do
      assert {:error, %Error{code: :validation_error, message: "definition must be a binary"}} =
               PubsubGrpc.validate_schema(@project, :avro, 123)

      assert {:error, %Error{code: :validation_error, message: "definition must be a binary"}} =
               PubsubGrpc.create_schema(@project, "schema", :avro, %{})

      assert {:error, %Error{code: :validation_error, message: "message must be a binary"}} =
               PubsubGrpc.validate_message(@project, "schema", :foo, :json)

      assert {:error, %Error{code: :validation_error, message: "message must be a binary"}} =
               PubsubGrpc.validate_message_with_schema(@project, :avro, "{}", :foo, :json)
    end

    test "an improper message list or a struct as attributes is a validation error" do
      for messages <- [
            [%{data: "a"} | %{data: "b"}],
            [%{data: 1}, %{data: "b"} | :tail],
            [%{data: "x", attributes: %URI{}}]
          ] do
        assert {:error, %Error{code: :validation_error}} =
                 PubsubGrpc.publish(@project, "topic", messages)
      end
    end

    test "an improper ack_ids list is a validation error" do
      for call <- [
            &PubsubGrpc.acknowledge(@project, "sub", &1),
            &PubsubGrpc.modify_ack_deadline(@project, "sub", &1, 30),
            &PubsubGrpc.nack(@project, "sub", &1)
          ] do
        assert {:error, %Error{code: :validation_error}} = call.(["a" | "b"])
      end
    end
  end

  describe "pull/3 with opts in place of max_messages" do
    test "takes the keyword list as opts and pulls 10 messages" do
      # Validation passes (max_messages defaults to 10); the pool does not exist.
      assert {:error, %Error{code: :connection_error}} =
               PubsubGrpc.pull(@project, "sub", pool: :pubsub_grpc_no_such_pool, timeout: 5_000)
    end
  end
end
