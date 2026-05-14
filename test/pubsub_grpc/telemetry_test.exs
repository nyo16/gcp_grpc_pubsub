defmodule PubsubGrpc.TelemetryTest do
  use ExUnit.Case, async: false

  alias PubsubGrpc.Telemetry

  setup do
    test_pid = self()
    handler_id = "test-handler-#{System.unique_integer([:positive])}"

    :telemetry.attach_many(
      handler_id,
      [
        [:pubsub_grpc, :request, :start],
        [:pubsub_grpc, :request, :stop],
        [:pubsub_grpc, :request, :exception]
      ],
      fn event, measurements, metadata, _config ->
        send(test_pid, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    :ok
  end

  test "span emits start and stop events on success" do
    result = Telemetry.span(:my_op, %{project_id: "p"}, fn -> {:ok, :payload} end)

    assert result == {:ok, :payload}

    assert_received {:telemetry, [:pubsub_grpc, :request, :start], _measurements,
                     %{operation: :my_op, project_id: "p"}}

    assert_received {:telemetry, [:pubsub_grpc, :request, :stop], %{duration: d},
                     %{operation: :my_op, result: :ok}}

    assert is_integer(d) and d >= 0
  end

  test "span classifies PubsubGrpc.Error in stop metadata" do
    err = PubsubGrpc.Error.new(:not_found, "missing")
    _ = Telemetry.span(:get_thing, %{}, fn -> {:error, err} end)

    assert_received {:telemetry, [:pubsub_grpc, :request, :stop], _,
                     %{operation: :get_thing, result: {:error, :not_found}}}
  end

  test "span emits exception event when wrapped fun raises" do
    assert_raise RuntimeError, "boom", fn ->
      Telemetry.span(:bad, %{}, fn -> raise "boom" end)
    end

    assert_received {:telemetry, [:pubsub_grpc, :request, :exception], _, %{operation: :bad}}
  end
end
