defmodule PubsubGrpc.TelemetryTest do
  use ExUnit.Case, async: true

  alias PubsubGrpc.{Error, Telemetry}

  @events [
    [:pubsub_grpc, :request, :start],
    [:pubsub_grpc, :request, :stop],
    [:pubsub_grpc, :request, :exception],
    [:pubsub_grpc, :auth, :start],
    [:pubsub_grpc, :auth, :stop],
    [:pubsub_grpc, :auth, :exception]
  ]

  setup do
    handler_id = "telemetry-test-#{System.unique_integer([:positive])}"
    :ok = :telemetry.attach_many(handler_id, @events, &__MODULE__.handle_event/4, self())
    on_exit(fn -> :telemetry.detach(handler_id) end)
    :ok
  end

  # Handlers run in the emitting process. Only forward this test's own events, so
  # concurrent async tests do not see each other's spans. `:telemetry_span_context`
  # is added by `:telemetry.span/3` itself.
  @doc false
  def handle_event(event, measurements, metadata, test_pid) do
    if self() == test_pid do
      metadata = Map.delete(metadata, :telemetry_span_context)
      send(test_pid, {:telemetry, event, measurements, metadata})
    end
  end

  describe "span/3" do
    test "emits start and stop events on success" do
      result = Telemetry.span(:my_op, %{project_id: "p"}, fn -> {:ok, :payload} end)

      assert result == {:ok, :payload}

      assert_received {:telemetry, [:pubsub_grpc, :request, :start], _measurements,
                       %{operation: :my_op, project_id: "p"}}

      assert_received {:telemetry, [:pubsub_grpc, :request, :stop], %{duration: d},
                       %{operation: :my_op, result: :ok}}

      assert is_integer(d) and d >= 0
    end

    test "classifies PubsubGrpc.Error in stop metadata" do
      err = Error.new(:not_found, "missing")
      _ = Telemetry.span(:get_thing, %{}, fn -> {:error, err} end)

      assert_received {:telemetry, [:pubsub_grpc, :request, :stop], _,
                       %{operation: :get_thing, result: {:error, :not_found}}}
    end

    test "emits an exception event when the wrapped fun raises" do
      assert_raise RuntimeError, "boom", fn ->
        Telemetry.span(:bad, %{}, fn -> raise "boom" end)
      end

      assert_received {:telemetry, [:pubsub_grpc, :request, :exception], _, %{operation: :bad}}
    end
  end

  describe "auth_span/2" do
    test "reports the source and classifies fetcher results like request spans" do
      for {source, result, expected} <- [
            {:goth, {:ok, "Bearer t", 1_000}, :ok},
            {:gcloud, {:error, Error.new(:deadline_exceeded, "slow")},
             {:error, :deadline_exceeded}},
            {:custom, {:error, Error.new(:unauthenticated, "no")}, {:error, :unauthenticated}}
          ] do
        assert ^result = Telemetry.auth_span(source, fn -> result end)

        assert_received {:telemetry, [:pubsub_grpc, :auth, :start], _, start_meta}
        assert start_meta == %{source: source}

        assert_received {:telemetry, [:pubsub_grpc, :auth, :stop], _, stop_meta}
        assert stop_meta == %{source: source, result: expected}
      end
    end
  end

  # Every public operation, called with an invalid project ID so it fails
  # validation without a network call; the span is still emitted. The expected
  # keys are the ones documented in the PubsubGrpc.Telemetry moduledoc.
  @operations [
    {:create_topic, [:project_id, :topic_id], &__MODULE__.call_create_topic/0},
    {:get_topic, [:project_id, :topic_id], &__MODULE__.call_get_topic/0},
    {:delete_topic, [:project_id, :topic_id], &__MODULE__.call_delete_topic/0},
    {:list_topics, [:project_id], &__MODULE__.call_list_topics/0},
    {:publish, [:project_id, :topic_id, :message_count], &__MODULE__.call_publish/0},
    {:publish, [:project_id, :topic_id, :message_count], &__MODULE__.call_publish_message/0},
    {:create_subscription, [:project_id, :topic_id, :subscription_id],
     &__MODULE__.call_create_subscription/0},
    {:get_subscription, [:project_id, :subscription_id], &__MODULE__.call_get_subscription/0},
    {:delete_subscription, [:project_id, :subscription_id],
     &__MODULE__.call_delete_subscription/0},
    {:list_subscriptions, [:project_id], &__MODULE__.call_list_subscriptions/0},
    {:pull, [:project_id, :subscription_id, :max_messages], &__MODULE__.call_pull/0},
    {:acknowledge, [:project_id, :subscription_id, :ack_count], &__MODULE__.call_acknowledge/0},
    {:modify_ack_deadline, [:project_id, :subscription_id, :ack_count, :ack_deadline_seconds],
     &__MODULE__.call_modify_ack_deadline/0},
    {:modify_ack_deadline, [:project_id, :subscription_id, :ack_count, :ack_deadline_seconds],
     &__MODULE__.call_nack/0},
    {:list_schemas, [:project_id], &__MODULE__.call_list_schemas/0},
    {:get_schema, [:project_id, :schema_id], &__MODULE__.call_get_schema/0},
    {:create_schema, [:project_id, :schema_id, :schema_type], &__MODULE__.call_create_schema/0},
    {:delete_schema, [:project_id, :schema_id], &__MODULE__.call_delete_schema/0},
    {:validate_schema, [:project_id, :schema_type], &__MODULE__.call_validate_schema/0},
    {:list_schema_revisions, [:project_id, :schema_id], &__MODULE__.call_list_schema_revisions/0},
    {:validate_message, [:project_id, :schema_name, :encoding],
     &__MODULE__.call_validate_message/0},
    {:validate_message_with_schema, [:project_id, :schema_type, :encoding],
     &__MODULE__.call_validate_message_with_schema/0}
  ]

  describe "operation metadata" do
    for {operation, keys, call} <- @operations do
      test "#{operation} via #{inspect(call)} emits the documented metadata keys" do
        operation = unquote(operation)
        expected = MapSet.new([:operation | unquote(keys)])

        assert {:error, %Error{code: :validation_error}} = unquote(call).()

        assert_received {:telemetry, [:pubsub_grpc, :request, :start], _, start_meta}
        assert start_meta.operation == operation
        assert MapSet.new(Map.keys(start_meta)) == expected

        assert_received {:telemetry, [:pubsub_grpc, :request, :stop], _, stop_meta}
        assert MapSet.new(Map.keys(stop_meta)) == MapSet.put(expected, :result)
        assert stop_meta.result == {:error, :validation_error}
      end
    end
  end

  @bad "Bad_Project"

  @doc false
  def call_create_topic, do: PubsubGrpc.create_topic(@bad, "topic")
  @doc false
  def call_get_topic, do: PubsubGrpc.get_topic(@bad, "topic")
  @doc false
  def call_delete_topic, do: PubsubGrpc.delete_topic(@bad, "topic")
  @doc false
  def call_list_topics, do: PubsubGrpc.list_topics(@bad)
  @doc false
  def call_publish, do: PubsubGrpc.publish(@bad, "topic", [%{data: "x"}])
  @doc false
  def call_publish_message, do: PubsubGrpc.publish_message(@bad, "topic", "x")
  @doc false
  def call_create_subscription, do: PubsubGrpc.create_subscription(@bad, "topic", "sub")
  @doc false
  def call_get_subscription, do: PubsubGrpc.get_subscription(@bad, "sub")
  @doc false
  def call_delete_subscription, do: PubsubGrpc.delete_subscription(@bad, "sub")
  @doc false
  def call_list_subscriptions, do: PubsubGrpc.list_subscriptions(@bad)
  @doc false
  def call_pull, do: PubsubGrpc.pull(@bad, "sub", 5)
  @doc false
  def call_acknowledge, do: PubsubGrpc.acknowledge(@bad, "sub", ["ack"])
  @doc false
  def call_modify_ack_deadline, do: PubsubGrpc.modify_ack_deadline(@bad, "sub", ["ack"], 30)
  @doc false
  def call_nack, do: PubsubGrpc.nack(@bad, "sub", ["ack"])
  @doc false
  def call_list_schemas, do: PubsubGrpc.list_schemas(@bad)
  @doc false
  def call_get_schema, do: PubsubGrpc.get_schema(@bad, "schema")
  @doc false
  def call_create_schema, do: PubsubGrpc.create_schema(@bad, "schema", :avro, "{}")
  @doc false
  def call_delete_schema, do: PubsubGrpc.delete_schema(@bad, "schema")
  @doc false
  def call_validate_schema, do: PubsubGrpc.validate_schema(@bad, :avro, "{}")
  @doc false
  def call_list_schema_revisions, do: PubsubGrpc.list_schema_revisions(@bad, "schema")
  @doc false
  def call_validate_message, do: PubsubGrpc.validate_message(@bad, "schema", "{}", :json)

  @doc false
  def call_validate_message_with_schema,
    do: PubsubGrpc.validate_message_with_schema(@bad, :avro, "{}", "{}", :json)
end
