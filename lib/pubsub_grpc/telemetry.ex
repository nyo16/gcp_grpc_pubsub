defmodule PubsubGrpc.Telemetry do
  @moduledoc """
  Telemetry events emitted by PubsubGrpc.

  ## Events

  All events share the prefix `[:pubsub_grpc, :request, _]` and are produced by
  `:telemetry.span/3`. Three events are emitted per operation:

    * `[:pubsub_grpc, :request, :start]` — measurements `%{system_time: integer, monotonic_time: integer}`
    * `[:pubsub_grpc, :request, :stop]` — measurements `%{duration: integer, monotonic_time: integer}`
    * `[:pubsub_grpc, :request, :exception]` — emitted when the wrapped function raises

  ## Metadata

  Start and stop events carry the operation context. Typical keys:

    * `:operation` — atom, e.g. `:publish`, `:pull`, `:acknowledge`, `:create_topic`
    * `:project_id` — Google Cloud project id (always present)
    * `:topic_id`, `:subscription_id`, `:schema_id` — when applicable
    * `:message_count` — for `:publish` and `:pull` (where known up front)

  Stop events additionally include:

    * `:result` — `:ok` for success, `{:error, error_code}` for known errors,
      `:unknown` for unexpected return shapes

  ## Example

      :telemetry.attach(
        "pubsub-grpc-logger",
        [:pubsub_grpc, :request, :stop],
        fn _event, %{duration: duration}, %{operation: op, result: result}, _config ->
          IO.inspect({op, result, System.convert_time_unit(duration, :native, :millisecond)})
        end,
        nil
      )

  ## Auth events

  Token fetches emit `[:pubsub_grpc, :auth, _]` events with the same three suffixes.
  Stop metadata includes `:source` (`:cache | :goth | :gcloud`) when available.
  """

  @event_prefix [:pubsub_grpc, :request]
  @auth_event_prefix [:pubsub_grpc, :auth]

  @spec span(atom(), map(), (-> result)) :: result when result: var
  def span(operation, metadata, fun) when is_atom(operation) and is_map(metadata) do
    start_meta = Map.put(metadata, :operation, operation)

    :telemetry.span(@event_prefix, start_meta, fn ->
      result = fun.()
      {result, Map.put(start_meta, :result, classify(result))}
    end)
  end

  @spec auth_span(map(), (-> result)) :: result when result: var
  def auth_span(metadata, fun) when is_map(metadata) do
    :telemetry.span(@auth_event_prefix, metadata, fn ->
      result = fun.()
      stop_meta = Map.merge(metadata, %{result: classify(result), source: auth_source(result)})
      {result, stop_meta}
    end)
  end

  defp classify(:ok), do: :ok
  defp classify({:ok, _}), do: :ok
  defp classify({:error, %PubsubGrpc.Error{code: code}}), do: {:error, code}
  defp classify({:error, _}), do: {:error, :unknown}
  defp classify(_), do: :unknown

  defp auth_source({:ok, _}), do: :network
  defp auth_source(_), do: :unknown
end
