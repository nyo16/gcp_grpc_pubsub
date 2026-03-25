defmodule PubsubGrpc do
  @moduledoc """
  Google Cloud Pub/Sub gRPC client with connection pooling.

  Provides a high-level API for Pub/Sub operations including topic and subscription
  management, message publishing, pulling, acknowledgment, and schema management.

  ## Configuration

  ### Production (Google Cloud)

      # Option 1: Goth Library (Recommended)
      config :pubsub_grpc, :goth, MyApp.Goth

      # Option 2: gcloud CLI (auto-detected)
      # Option 3: GOOGLE_APPLICATION_CREDENTIALS env var
      # Option 4: GCE/GKE metadata (automatic)

  ### Development/Test (Local Emulator)

      config :pubsub_grpc, :emulator,
        project_id: "my-project-id",
        host: "localhost",
        port: 8085

  ### Timeouts

      # Global default (30s by default)
      config :pubsub_grpc, :default_timeout, 30_000

  ## Error Handling

  All functions return `{:ok, result}` or `{:error, %PubsubGrpc.Error{}}`.
  Pattern match on the error code for specific handling:

      case PubsubGrpc.create_topic("my-project", "my-topic") do
        {:ok, topic} -> topic
        {:error, %PubsubGrpc.Error{code: :already_exists}} -> "already exists"
        {:error, %PubsubGrpc.Error{code: :unauthenticated}} -> "auth failed"
        {:error, %PubsubGrpc.Error{} = err} -> "Error: \#{err}"
      end

  ## Examples

      # Create a topic
      {:ok, topic} = PubsubGrpc.create_topic("my-project", "my-topic")

      # Publish messages
      messages = [%{data: "Hello", attributes: %{"source" => "app"}}]
      {:ok, response} = PubsubGrpc.publish("my-project", "my-topic", messages)

      # Create subscription and pull
      {:ok, sub} = PubsubGrpc.create_subscription("my-project", "my-topic", "my-sub")
      {:ok, messages} = PubsubGrpc.pull("my-project", "my-sub", 10)

      # Acknowledge
      ack_ids = Enum.map(messages, & &1.ack_id)
      :ok = PubsubGrpc.acknowledge("my-project", "my-sub", ack_ids)

  """

  alias PubsubGrpc.{Client, Error, Schema, Validation}

  # Topics

  @doc """
  Creates a new Pub/Sub topic.

  ## Parameters
  - `project_id` - Google Cloud project ID
  - `topic_id` - Topic identifier (without full path)

  ## Returns
  - `{:ok, %Google.Pubsub.V1.Topic{}}` on success
  - `{:error, %PubsubGrpc.Error{code: :already_exists}}` if topic exists
  - `{:error, %PubsubGrpc.Error{}}` on other errors

  """
  @spec create_topic(String.t(), String.t()) ::
          {:ok, Google.Pubsub.V1.Topic.t()} | {:error, Error.t()}
  def create_topic(project_id, topic_id) do
    with {:ok, _} <- Validation.validate_project_id(project_id),
         {:ok, _} <- Validation.validate_topic_id(topic_id),
         {:ok, grpc_opts} <- grpc_opts() do
      topic_path = topic_path(project_id, topic_id)

      fn channel ->
        request = %Google.Pubsub.V1.Topic{name: topic_path}
        Google.Pubsub.V1.Publisher.Stub.create_topic(channel, request, grpc_opts)
      end
      |> Client.execute()
      |> unwrap_result()
    end
  end

  @doc """
  Gets details of a topic.

  ## Returns
  - `{:ok, %Google.Pubsub.V1.Topic{}}` on success
  - `{:error, %PubsubGrpc.Error{code: :not_found}}` if topic doesn't exist

  """
  @spec get_topic(String.t(), String.t()) ::
          {:ok, Google.Pubsub.V1.Topic.t()} | {:error, Error.t()}
  def get_topic(project_id, topic_id) do
    with {:ok, _} <- Validation.validate_project_id(project_id),
         {:ok, _} <- Validation.validate_topic_id(topic_id),
         {:ok, grpc_opts} <- grpc_opts() do
      topic_path = topic_path(project_id, topic_id)

      fn channel ->
        request = %Google.Pubsub.V1.GetTopicRequest{topic: topic_path}
        Google.Pubsub.V1.Publisher.Stub.get_topic(channel, request, grpc_opts)
      end
      |> Client.execute()
      |> unwrap_result()
    end
  end

  @doc """
  Deletes a Pub/Sub topic.

  ## Returns
  - `:ok` on success
  - `{:error, %PubsubGrpc.Error{}}` on error

  """
  @spec delete_topic(String.t(), String.t()) :: :ok | {:error, Error.t()}
  def delete_topic(project_id, topic_id) do
    with {:ok, _} <- Validation.validate_project_id(project_id),
         {:ok, _} <- Validation.validate_topic_id(topic_id),
         {:ok, grpc_opts} <- grpc_opts() do
      topic_path = topic_path(project_id, topic_id)

      fn channel ->
        request = %Google.Pubsub.V1.DeleteTopicRequest{topic: topic_path}
        Google.Pubsub.V1.Publisher.Stub.delete_topic(channel, request, grpc_opts)
      end
      |> Client.execute()
      |> unwrap_empty_result()
    end
  end

  @doc """
  Lists topics in a project.

  ## Options
  - `:page_size` - Maximum number of topics to return
  - `:page_token` - Token for pagination

  ## Returns
  - `{:ok, %{topics: [topic], next_page_token: token}}`

  """
  @spec list_topics(String.t(), keyword()) ::
          {:ok, %{topics: list(), next_page_token: String.t()}} | {:error, Error.t()}
  def list_topics(project_id, opts \\ []) do
    with {:ok, _} <- Validation.validate_project_id(project_id),
         {:ok, grpc_opts} <- grpc_opts() do
      project_path = "projects/#{project_id}"

      fn channel ->
        request = %Google.Pubsub.V1.ListTopicsRequest{
          project: project_path,
          page_size: Keyword.get(opts, :page_size, 0),
          page_token: Keyword.get(opts, :page_token, "")
        }

        Google.Pubsub.V1.Publisher.Stub.list_topics(channel, request, grpc_opts)
      end
      |> Client.execute()
      |> unwrap_list_result(:topics, :next_page_token)
    end
  end

  # Publishing

  @doc """
  Publishes messages to a topic.

  ## Parameters
  - `messages` - Non-empty list of message maps, each with `:data` (binary)
    and/or `:attributes` (map)

  ## Returns
  - `{:ok, %{message_ids: [String.t()]}}`

  ## Examples

      messages = [
        %{data: "Hello World", attributes: %{"source" => "app"}},
        %{data: "Another message"}
      ]
      {:ok, response} = PubsubGrpc.publish("my-project", "my-topic", messages)

  """
  @spec publish(String.t(), String.t(), [map()]) ::
          {:ok, %{message_ids: [String.t()]}} | {:error, Error.t()}
  def publish(project_id, topic_id, messages) do
    with {:ok, _} <- Validation.validate_project_id(project_id),
         {:ok, _} <- Validation.validate_topic_id(topic_id),
         {:ok, _} <- Validation.validate_messages(messages),
         {:ok, grpc_opts} <- grpc_opts() do
      topic_path = topic_path(project_id, topic_id)

      pubsub_messages =
        Enum.map(messages, fn msg ->
          %Google.Pubsub.V1.PubsubMessage{
            data: Map.get(msg, :data, ""),
            attributes: Map.get(msg, :attributes, %{})
          }
        end)

      fn channel ->
        request = %Google.Pubsub.V1.PublishRequest{
          topic: topic_path,
          messages: pubsub_messages
        }

        Google.Pubsub.V1.Publisher.Stub.publish(channel, request, grpc_opts)
      end
      |> Client.execute()
      |> case do
        {:ok, {:ok, response}} -> {:ok, %{message_ids: response.message_ids}}
        other -> unwrap_error(other)
      end
    end
  end

  @doc """
  Convenience function to publish a single message.
  """
  @spec publish_message(String.t(), String.t(), binary(), map()) ::
          {:ok, %{message_ids: [String.t()]}} | {:error, Error.t()}
  def publish_message(project_id, topic_id, data, attributes \\ %{}) do
    publish(project_id, topic_id, [%{data: data, attributes: attributes}])
  end

  # Subscriptions

  @doc """
  Creates a subscription to a topic.

  ## Options
  - `:ack_deadline_seconds` - Ack deadline in seconds (10-600, default: 60)

  """
  @spec create_subscription(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, Google.Pubsub.V1.Subscription.t()} | {:error, Error.t()}
  def create_subscription(project_id, topic_id, subscription_id, opts \\ []) do
    ack_deadline = Keyword.get(opts, :ack_deadline_seconds, 60)

    with {:ok, _} <- Validation.validate_project_id(project_id),
         {:ok, _} <- Validation.validate_topic_id(topic_id),
         {:ok, _} <- Validation.validate_subscription_id(subscription_id),
         {:ok, _} <- Validation.validate_ack_deadline(ack_deadline),
         {:ok, grpc_opts} <- grpc_opts() do
      topic_path = topic_path(project_id, topic_id)
      subscription_path = subscription_path(project_id, subscription_id)

      fn channel ->
        request = %Google.Pubsub.V1.Subscription{
          name: subscription_path,
          topic: topic_path,
          ack_deadline_seconds: ack_deadline
        }

        Google.Pubsub.V1.Subscriber.Stub.create_subscription(channel, request, grpc_opts)
      end
      |> Client.execute()
      |> unwrap_result()
    end
  end

  @doc """
  Gets details of a subscription.

  ## Returns
  - `{:ok, %Google.Pubsub.V1.Subscription{}}` on success
  - `{:error, %PubsubGrpc.Error{code: :not_found}}` if subscription doesn't exist

  """
  @spec get_subscription(String.t(), String.t()) ::
          {:ok, Google.Pubsub.V1.Subscription.t()} | {:error, Error.t()}
  def get_subscription(project_id, subscription_id) do
    with {:ok, _} <- Validation.validate_project_id(project_id),
         {:ok, _} <- Validation.validate_subscription_id(subscription_id),
         {:ok, grpc_opts} <- grpc_opts() do
      subscription_path = subscription_path(project_id, subscription_id)

      fn channel ->
        request = %Google.Pubsub.V1.GetSubscriptionRequest{subscription: subscription_path}
        Google.Pubsub.V1.Subscriber.Stub.get_subscription(channel, request, grpc_opts)
      end
      |> Client.execute()
      |> unwrap_result()
    end
  end

  @doc """
  Deletes a subscription.

  ## Returns
  - `:ok` on success

  """
  @spec delete_subscription(String.t(), String.t()) :: :ok | {:error, Error.t()}
  def delete_subscription(project_id, subscription_id) do
    with {:ok, _} <- Validation.validate_project_id(project_id),
         {:ok, _} <- Validation.validate_subscription_id(subscription_id),
         {:ok, grpc_opts} <- grpc_opts() do
      subscription_path = subscription_path(project_id, subscription_id)

      fn channel ->
        request = %Google.Pubsub.V1.DeleteSubscriptionRequest{subscription: subscription_path}
        Google.Pubsub.V1.Subscriber.Stub.delete_subscription(channel, request, grpc_opts)
      end
      |> Client.execute()
      |> unwrap_empty_result()
    end
  end

  @doc """
  Lists subscriptions in a project.

  ## Options
  - `:page_size` - Maximum number of subscriptions to return
  - `:page_token` - Token for pagination

  ## Returns
  - `{:ok, %{subscriptions: [subscription], next_page_token: token}}`

  """
  @spec list_subscriptions(String.t(), keyword()) ::
          {:ok, %{subscriptions: list(), next_page_token: String.t()}} | {:error, Error.t()}
  def list_subscriptions(project_id, opts \\ []) do
    with {:ok, _} <- Validation.validate_project_id(project_id),
         {:ok, grpc_opts} <- grpc_opts() do
      project_path = "projects/#{project_id}"

      fn channel ->
        request = %Google.Pubsub.V1.ListSubscriptionsRequest{
          project: project_path,
          page_size: Keyword.get(opts, :page_size, 0),
          page_token: Keyword.get(opts, :page_token, "")
        }

        Google.Pubsub.V1.Subscriber.Stub.list_subscriptions(channel, request, grpc_opts)
      end
      |> Client.execute()
      |> unwrap_list_result(:subscriptions, :next_page_token)
    end
  end

  # Message Operations

  @doc """
  Pulls messages from a subscription.

  ## Parameters
  - `max_messages` - Maximum number of messages to pull (default: 10, must be positive)

  ## Returns
  - `{:ok, [%Google.Pubsub.V1.ReceivedMessage{}]}`

  """
  @spec pull(String.t(), String.t(), pos_integer()) ::
          {:ok, list()} | {:error, Error.t()}
  def pull(project_id, subscription_id, max_messages \\ 10) do
    with {:ok, _} <- Validation.validate_project_id(project_id),
         {:ok, _} <- Validation.validate_subscription_id(subscription_id),
         {:ok, _} <- Validation.validate_max_messages(max_messages),
         {:ok, grpc_opts} <- grpc_opts() do
      subscription_path = subscription_path(project_id, subscription_id)

      fn channel ->
        request = %Google.Pubsub.V1.PullRequest{
          subscription: subscription_path,
          max_messages: max_messages
        }

        Google.Pubsub.V1.Subscriber.Stub.pull(channel, request, grpc_opts)
      end
      |> Client.execute()
      |> case do
        {:ok, {:ok, response}} -> {:ok, response.received_messages}
        other -> unwrap_error(other)
      end
    end
  end

  @doc """
  Acknowledges received messages.

  ## Parameters
  - `ack_ids` - Non-empty list of acknowledgment IDs from received messages

  ## Returns
  - `:ok` on success

  """
  @spec acknowledge(String.t(), String.t(), [String.t()]) :: :ok | {:error, Error.t()}
  def acknowledge(project_id, subscription_id, ack_ids) do
    with {:ok, _} <- Validation.validate_project_id(project_id),
         {:ok, _} <- Validation.validate_subscription_id(subscription_id),
         {:ok, _} <- Validation.validate_ack_ids(ack_ids),
         {:ok, grpc_opts} <- grpc_opts() do
      subscription_path = subscription_path(project_id, subscription_id)

      fn channel ->
        request = %Google.Pubsub.V1.AcknowledgeRequest{
          subscription: subscription_path,
          ack_ids: ack_ids
        }

        Google.Pubsub.V1.Subscriber.Stub.acknowledge(channel, request, grpc_opts)
      end
      |> Client.execute()
      |> unwrap_empty_result()
    end
  end

  @doc """
  Modifies the ack deadline for received messages.

  Setting `ack_deadline_seconds` to 0 causes immediate redelivery (nack).
  Use `nack/3` as a convenience for this.

  ## Parameters
  - `ack_ids` - Non-empty list of acknowledgment IDs
  - `ack_deadline_seconds` - New deadline in seconds (0-600)

  ## Returns
  - `:ok` on success

  """
  @spec modify_ack_deadline(String.t(), String.t(), [String.t()], non_neg_integer()) ::
          :ok | {:error, Error.t()}
  def modify_ack_deadline(project_id, subscription_id, ack_ids, ack_deadline_seconds) do
    with {:ok, _} <- Validation.validate_project_id(project_id),
         {:ok, _} <- Validation.validate_subscription_id(subscription_id),
         {:ok, _} <- Validation.validate_ack_ids(ack_ids),
         {:ok, _} <- Validation.validate_ack_deadline_with_zero(ack_deadline_seconds),
         {:ok, grpc_opts} <- grpc_opts() do
      subscription_path = subscription_path(project_id, subscription_id)

      fn channel ->
        request = %Google.Pubsub.V1.ModifyAckDeadlineRequest{
          subscription: subscription_path,
          ack_ids: ack_ids,
          ack_deadline_seconds: ack_deadline_seconds
        }

        Google.Pubsub.V1.Subscriber.Stub.modify_ack_deadline(channel, request, grpc_opts)
      end
      |> Client.execute()
      |> unwrap_empty_result()
    end
  end

  @doc """
  Negatively acknowledges messages, causing immediate redelivery.

  This is a convenience wrapper around `modify_ack_deadline/4` with a deadline of 0.

  ## Parameters
  - `ack_ids` - Non-empty list of acknowledgment IDs

  ## Returns
  - `:ok` on success

  """
  @spec nack(String.t(), String.t(), [String.t()]) :: :ok | {:error, Error.t()}
  def nack(project_id, subscription_id, ack_ids) do
    modify_ack_deadline(project_id, subscription_id, ack_ids, 0)
  end

  # Custom Operations

  @doc """
  Executes a custom gRPC operation using a connection from the pool.

  The function receives a gRPC channel and should return the result of a
  gRPC stub call.

  ## Examples

      operation = fn channel ->
        request = %Google.Pubsub.V1.GetTopicRequest{topic: "projects/my-project/topics/my-topic"}
        opts = PubsubGrpc.Auth.request_opts()
        Google.Pubsub.V1.Publisher.Stub.get_topic(channel, request, opts)
      end

      {:ok, topic} = PubsubGrpc.execute(operation)

  """
  @spec execute((GRPC.Channel.t() -> term()), keyword()) ::
          {:ok, term()} | {:error, Error.t()}
  def execute(operation_fn, opts \\ []) when is_function(operation_fn, 1) do
    Client.execute(operation_fn, opts) |> unwrap_result()
  end

  @doc """
  Executes multiple operations using the same connection.

  More efficient when performing several operations in sequence.

  ## Examples

      result = PubsubGrpc.with_connection(fn channel ->
        auth_opts = PubsubGrpc.Auth.request_opts()
        # ... multiple operations on channel
      end)

  """
  @spec with_connection((GRPC.Channel.t() -> term()), keyword()) ::
          {:ok, term()} | {:error, Error.t()}
  def with_connection(fun, opts \\ []) when is_function(fun, 1) do
    Client.execute(fun, opts) |> unwrap_result()
  end

  # Schema management (delegated)

  @doc """
  Lists schemas in a project.

  ## Options
  - `:view` - `:basic` or `:full` (default: `:basic`)
  - `:page_size` - Maximum number of schemas to return
  - `:page_token` - Token for pagination

  """
  defdelegate list_schemas(project_id, opts \\ []), to: Schema

  @doc """
  Gets details of a specific schema.

  ## Options
  - `:view` - `:basic` or `:full` (default: `:full`)

  """
  defdelegate get_schema(project_id, schema_id, opts \\ []), to: Schema

  @doc """
  Creates a new schema.

  ## Parameters
  - `type` - `:protocol_buffer` or `:avro`
  - `definition` - The schema definition string

  """
  defdelegate create_schema(project_id, schema_id, type, definition), to: Schema

  @doc """
  Deletes a schema.
  """
  defdelegate delete_schema(project_id, schema_id), to: Schema

  @doc """
  Validates a schema definition.
  """
  defdelegate validate_schema(project_id, type, definition), to: Schema

  @doc """
  Lists revisions of a schema.
  """
  defdelegate list_schema_revisions(project_id, schema_id, opts \\ []), to: Schema

  @doc """
  Validates a message against an existing schema.

  ## Parameters
  - `schema_name` - Full schema resource name or just the schema ID
  - `message` - Message bytes to validate
  - `encoding` - `:json` or `:binary`

  """
  defdelegate validate_message(project_id, schema_name, message, encoding), to: Schema

  @doc """
  Validates a message against an inline schema definition.

  ## Parameters
  - `type` - `:protocol_buffer` or `:avro`
  - `definition` - Schema definition string
  - `message` - Message bytes to validate
  - `encoding` - `:json` or `:binary`

  """
  defdelegate validate_message_with_schema(project_id, type, definition, message, encoding),
    to: Schema

  # Private helpers

  defp grpc_opts do
    timeout = Application.get_env(:pubsub_grpc, :default_timeout, 30_000)

    case PubsubGrpc.Auth.request_opts() do
      {:ok, opts} -> {:ok, opts ++ [timeout: timeout]}
      {:error, _} = error -> error
    end
  end

  defp topic_path(project_id, topic_id) do
    "projects/#{project_id}/topics/#{topic_id}"
  end

  defp subscription_path(project_id, subscription_id) do
    "projects/#{project_id}/subscriptions/#{subscription_id}"
  end

  defp unwrap_result({:ok, {:ok, result}}), do: {:ok, result}
  defp unwrap_result(other), do: unwrap_error(other)

  defp unwrap_empty_result({:ok, {:ok, %Google.Protobuf.Empty{}}}), do: :ok
  defp unwrap_empty_result(other), do: unwrap_error(other)

  defp unwrap_list_result({:ok, {:ok, response}}, items_key, token_key) do
    {:ok, %{items_key => Map.get(response, items_key), token_key => Map.get(response, token_key)}}
  end

  defp unwrap_list_result(other, _items_key, _token_key), do: unwrap_error(other)

  defp unwrap_error({:ok, {:error, %GRPC.RPCError{} = error}}) do
    {:error, Error.from_grpc_error(error)}
  end

  defp unwrap_error({:ok, {:error, error}}) do
    {:error, Error.new(:internal, "unexpected error: #{inspect(error)}", error)}
  end

  defp unwrap_error({:error, reason}) do
    {:error, Error.new(:connection_error, "connection error: #{inspect(reason)}", reason)}
  end
end
