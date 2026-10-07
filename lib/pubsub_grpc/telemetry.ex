defmodule PubsubGrpc.Telemetry do
  @moduledoc """
  Telemetry events emitted by PubsubGrpc.

  ## Request events

  Every public operation of `PubsubGrpc` and `PubsubGrpc.Schema` is wrapped in a
  `:telemetry.span/3` with the prefix `[:pubsub_grpc, :request]`:

    * `[:pubsub_grpc, :request, :start]` — measurements `%{system_time: integer, monotonic_time: integer}`
    * `[:pubsub_grpc, :request, :stop]` — measurements `%{duration: integer, monotonic_time: integer}`
    * `[:pubsub_grpc, :request, :exception]` — emitted when the operation raises

  Events are emitted for every call, including calls rejected by input
  validation. `PubsubGrpc.execute/2` and `PubsubGrpc.with_connection/2` emit no
  events.

  ### Metadata

  Start and stop metadata contain `:operation` (the function name as an atom)
  plus these keys:

  | `:operation` | Keys |
  |---|---|
  | `:create_topic`, `:get_topic`, `:delete_topic` | `:project_id`, `:topic_id` |
  | `:list_topics`, `:list_subscriptions`, `:list_schemas` | `:project_id` |
  | `:publish` (also used by `publish_message`) | `:project_id`, `:topic_id`, `:message_count` |
  | `:create_subscription` | `:project_id`, `:topic_id`, `:subscription_id` |
  | `:get_subscription`, `:delete_subscription` | `:project_id`, `:subscription_id` |
  | `:pull` | `:project_id`, `:subscription_id`, `:max_messages` |
  | `:acknowledge` | `:project_id`, `:subscription_id`, `:ack_count` |
  | `:modify_ack_deadline` (also used by `nack`) | `:project_id`, `:subscription_id`, `:ack_count`, `:ack_deadline_seconds` |
  | `:get_schema`, `:delete_schema`, `:list_schema_revisions` | `:project_id`, `:schema_id` |
  | `:create_schema` | `:project_id`, `:schema_id`, `:schema_type` |
  | `:validate_schema` | `:project_id`, `:schema_type` |
  | `:validate_message` | `:project_id`, `:schema_name`, `:encoding` |
  | `:validate_message_with_schema` | `:project_id`, `:schema_type`, `:encoding` |

  The values are the arguments as passed (`:message_count` and `:ack_count` are
  list lengths, `0` for a non-list).

  Stop metadata additionally contains `:result`: `:ok` on success,
  `{:error, code}` with the `PubsubGrpc.Error` code on failure.

  ## Auth events

  A token fetch emits `[:pubsub_grpc, :auth, :start | :stop | :exception]`, once per
  real fetch: cache hits emit nothing, and concurrent callers waiting for the same
  fetch share one span. Start and stop metadata contain `:source`, one of
  `:goth`, `:gcloud` or `:custom`; stop metadata also contains `:result`, with
  the same shape as for request events.

  `:telemetry.span/3` also adds its own `:telemetry_span_context` key to all of
  these events.

  ## Example

      :telemetry.attach(
        "pubsub-grpc-logger",
        [:pubsub_grpc, :request, :stop],
        fn _event, %{duration: duration}, %{operation: op, result: result}, _config ->
          IO.inspect({op, result, System.convert_time_unit(duration, :native, :millisecond)})
        end,
        nil
      )
  """

  alias PubsubGrpc.Error

  @event_prefix [:pubsub_grpc, :request]
  @auth_event_prefix [:pubsub_grpc, :auth]

  @doc false
  @spec span(atom(), map(), (-> result)) :: result when result: var
  def span(operation, metadata, fun) when is_atom(operation) and is_map(metadata) do
    start_meta = Map.put(metadata, :operation, operation)

    :telemetry.span(@event_prefix, start_meta, fn ->
      result = fun.()
      {result, Map.put(start_meta, :result, classify(result))}
    end)
  end

  @doc false
  @spec auth_span(:goth | :gcloud | :custom, (-> result)) :: result when result: var
  def auth_span(source, fun) when source in [:goth, :gcloud, :custom] do
    metadata = %{source: source}

    :telemetry.span(@auth_event_prefix, metadata, fn ->
      result = fun.()
      {result, Map.put(metadata, :result, classify(result))}
    end)
  end

  defp classify(:ok), do: :ok
  defp classify({:ok, _}), do: :ok
  # Auth fetchers return `{:ok, token, ttl_ms}`.
  defp classify({:ok, _, _}), do: :ok
  defp classify({:error, %Error{code: code}}), do: {:error, code}
  defp classify({:error, _}), do: {:error, :unknown}
  defp classify(_), do: :unknown
end
