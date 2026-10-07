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

  ### Supervising the connection pool yourself

  By default the `:pubsub_grpc` application starts the connection pool. To start
  it in your own supervision tree instead (for example to control start order),
  disable the built-in pool and add `PubsubGrpc` as a child:

      # config/config.exs
      config :pubsub_grpc, :start_pool, false

      # MyApp.Application
      children = [
        PubsubGrpc,
        # ... processes that use PubsubGrpc
      ]

  The pool is configured from the same application env as the built-in one (see
  `PubsubGrpc.Application`). See `child_spec/1`.

  ## Common options

  Every operation takes a trailing keyword list `opts` that accepts:

    * `:timeout` - deadline for the gRPC call itself, in milliseconds (default:
      the `:default_timeout` app env, 30_000). Waits before the call are not
      included and come on top of it: up to `min(timeout, 2_000)` for a pool
      connection when none is ready, and up to `:auth_timeout` (10 s by
      default) for a token fetch on a cache miss.
    * `:pool` - name of the connection pool to use (default: the configured pool,
      `PubsubGrpc.ConnectionPool` unless set in `config :pubsub_grpc, GrpcConnectionPool`).
      The auth token is attached only if the checked-out connection uses TLS, so
      any TLS pool passed as `:pool` receives the bearer token: only point it at
      trusted Google endpoints.

  Operations with their own options (e.g. `list_topics/2`, `pull/4`) accept the
  common options in the same keyword list.

  ## Request limits

  Requests that are certain to exceed a Pub/Sub limit are rejected locally with
  `{:error, %PubsubGrpc.Error{code: :validation_error}}` and a message naming the
  limit: at most 1,000 messages and 10 MiB of message data and attribute keys and
  values per `publish/4`, and 512 KiB of ack IDs per `acknowledge/4`,
  `modify_ack_deadline/5` and `nack/4`
  ([Pub/Sub quotas](https://cloud.google.com/pubsub/quotas#resource_limits)).

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

      # Per-call timeout
      {:ok, topic} = PubsubGrpc.get_topic("my-project", "my-topic", timeout: 5_000)

  """

  alias Google.Pubsub.V1, as: PubsubV1
  alias PubsubGrpc.{Client, Config, Error, Request, Result, Schema, Telemetry, Validation}
  alias PubsubV1.Publisher.Stub, as: PublisherStub
  alias PubsubV1.Subscriber.Stub, as: SubscriberStub

  @typedoc "A Pub/Sub topic (`%Google.Pubsub.V1.Topic{}`)."
  @type topic :: %Google.Pubsub.V1.Topic{}

  @typedoc "A Pub/Sub subscription (`%Google.Pubsub.V1.Subscription{}`)."
  @type subscription :: %Google.Pubsub.V1.Subscription{}

  @doc """
  Child spec for the Pub/Sub connection pool, configured from the `:pubsub_grpc`
  application env exactly like the pool the application starts by default.

  Use it with `config :pubsub_grpc, :start_pool, false`; otherwise the pool is
  already running and starting a second one fails. Takes no options:
  `PubsubGrpc` and `{PubsubGrpc, []}` are equivalent.
  """
  @spec child_spec([]) :: Supervisor.child_spec()
  def child_spec([]) do
    Supervisor.child_spec({GrpcConnectionPool, Config.pool_config()}, id: __MODULE__)
  end

  # Topics

  @doc """
  Creates a new Pub/Sub topic.

  ## Parameters
  - `project_id` - Google Cloud project ID
  - `topic_id` - Topic identifier (without full path)
  - `opts` - [common options](#module-common-options)

  ## Returns
  - `{:ok, %Google.Pubsub.V1.Topic{}}` on success
  - `{:error, %PubsubGrpc.Error{code: :already_exists}}` if topic exists
  - `{:error, %PubsubGrpc.Error{}}` on other errors

  """
  @spec create_topic(String.t(), String.t(), keyword()) ::
          {:ok, topic()} | {:error, Error.t()}
  def create_topic(project_id, topic_id, opts \\ []) do
    Telemetry.span(:create_topic, %{project_id: project_id, topic_id: topic_id}, fn ->
      do_create_topic(project_id, topic_id, opts)
    end)
  end

  defp do_create_topic(project_id, topic_id, opts) do
    with {:ok, _} <- Validation.validate_project_id(project_id),
         {:ok, _} <- Validation.validate_topic_id(topic_id) do
      request = %PubsubV1.Topic{name: Request.topic_path(project_id, topic_id)}

      fn channel, grpc_opts -> PublisherStub.create_topic(channel, request, grpc_opts) end
      |> Request.execute(opts)
      |> Result.unwrap()
    end
  end

  @doc """
  Gets details of a topic.

  Accepts the [common options](#module-common-options).

  ## Returns
  - `{:ok, %Google.Pubsub.V1.Topic{}}` on success
  - `{:error, %PubsubGrpc.Error{code: :not_found}}` if topic doesn't exist

  """
  @spec get_topic(String.t(), String.t(), keyword()) ::
          {:ok, topic()} | {:error, Error.t()}
  def get_topic(project_id, topic_id, opts \\ []) do
    Telemetry.span(:get_topic, %{project_id: project_id, topic_id: topic_id}, fn ->
      do_get_topic(project_id, topic_id, opts)
    end)
  end

  defp do_get_topic(project_id, topic_id, opts) do
    with {:ok, _} <- Validation.validate_project_id(project_id),
         {:ok, _} <- Validation.validate_topic_id(topic_id) do
      request = %PubsubV1.GetTopicRequest{topic: Request.topic_path(project_id, topic_id)}

      fn channel, grpc_opts -> PublisherStub.get_topic(channel, request, grpc_opts) end
      |> Request.execute(opts)
      |> Result.unwrap()
    end
  end

  @doc """
  Deletes a Pub/Sub topic.

  Accepts the [common options](#module-common-options).

  ## Returns
  - `:ok` on success
  - `{:error, %PubsubGrpc.Error{}}` on error

  """
  @spec delete_topic(String.t(), String.t(), keyword()) :: :ok | {:error, Error.t()}
  def delete_topic(project_id, topic_id, opts \\ []) do
    Telemetry.span(:delete_topic, %{project_id: project_id, topic_id: topic_id}, fn ->
      do_delete_topic(project_id, topic_id, opts)
    end)
  end

  defp do_delete_topic(project_id, topic_id, opts) do
    with {:ok, _} <- Validation.validate_project_id(project_id),
         {:ok, _} <- Validation.validate_topic_id(topic_id) do
      request = %PubsubV1.DeleteTopicRequest{topic: Request.topic_path(project_id, topic_id)}

      fn channel, grpc_opts -> PublisherStub.delete_topic(channel, request, grpc_opts) end
      |> Request.execute(opts)
      |> Result.unwrap_empty()
    end
  end

  @doc """
  Lists topics in a project.

  ## Options
  - `:page_size` - Maximum number of topics to return
  - `:page_token` - Token for pagination
  - [common options](#module-common-options)

  ## Returns
  - `{:ok, %{topics: [topic], next_page_token: token}}`

  """
  @spec list_topics(String.t(), keyword()) ::
          {:ok, %{topics: list(), next_page_token: String.t()}} | {:error, Error.t()}
  def list_topics(project_id, opts \\ []) do
    Telemetry.span(:list_topics, %{project_id: project_id}, fn ->
      do_list_topics(project_id, opts)
    end)
  end

  defp do_list_topics(project_id, opts) do
    with {:ok, _} <- Validation.validate_project_id(project_id) do
      request = %PubsubV1.ListTopicsRequest{
        project: Request.project_path(project_id),
        page_size: Keyword.get(opts, :page_size, 0),
        page_token: Keyword.get(opts, :page_token, "")
      }

      fn channel, grpc_opts -> PublisherStub.list_topics(channel, request, grpc_opts) end
      |> Request.execute(opts)
      |> Result.unwrap_list(:topics, :next_page_token)
    end
  end

  # Publishing

  @doc """
  Publishes messages to a topic.

  ## Parameters
  - `messages` - Non-empty list of message maps, each with `:data` (binary)
    and/or `:attributes` (map). At most 1,000 messages and 10 MiB of data and
    attributes (see [Request limits](#module-request-limits)).
  - `opts` - [common options](#module-common-options)

  ## Returns
  - `{:ok, %{message_ids: [String.t()]}}`

  ## Examples

      messages = [
        %{data: "Hello World", attributes: %{"source" => "app"}},
        %{data: "Another message"}
      ]
      {:ok, response} = PubsubGrpc.publish("my-project", "my-topic", messages)

  """
  @spec publish(String.t(), String.t(), [map()], keyword()) ::
          {:ok, %{message_ids: [String.t()]}} | {:error, Error.t()}
  def publish(project_id, topic_id, messages, opts \\ []) do
    # Validates and builds the request messages in one pass, before the span, so
    # the span metadata can carry the message count.
    prepared = Validation.build_publish_messages(messages)

    message_count =
      case prepared do
        {:ok, _messages, count} -> count
        {:error, _} when is_list(messages) -> length(messages)
        {:error, _} -> 0
      end

    Telemetry.span(
      :publish,
      %{project_id: project_id, topic_id: topic_id, message_count: message_count},
      fn -> do_publish(project_id, topic_id, prepared, opts) end
    )
  end

  defp do_publish(project_id, topic_id, prepared, opts) do
    with {:ok, _} <- Validation.validate_project_id(project_id),
         {:ok, _} <- Validation.validate_topic_id(topic_id),
         {:ok, pubsub_messages, _count} <- prepared do
      request = %PubsubV1.PublishRequest{
        topic: Request.topic_path(project_id, topic_id),
        messages: pubsub_messages
      }

      fn channel, grpc_opts -> PublisherStub.publish(channel, request, grpc_opts) end
      |> Request.execute(opts)
      |> case do
        {:ok, {:ok, response}} -> {:ok, %{message_ids: response.message_ids}}
        other -> Result.unwrap_error(other)
      end
    end
  end

  @doc """
  Convenience function to publish a single message.

  `opts` are the [common options](#module-common-options). Without attributes,
  they can be passed in place of `attributes`:
  `publish_message(project_id, topic_id, data, timeout: 5_000)`. A list in that
  position is taken as options only if it is a keyword list of common options
  (`:timeout`, `:pool`); any other list is validated as attributes (and rejected,
  since attributes must be a map).
  """
  @spec publish_message(String.t(), String.t(), binary(), map() | keyword(), keyword()) ::
          {:ok, %{message_ids: [String.t()]}} | {:error, Error.t()}
  def publish_message(project_id, topic_id, data, attributes \\ %{}, opts \\ [])

  def publish_message(project_id, topic_id, data, [_ | _] = maybe_opts, []) do
    if common_opts?(maybe_opts),
      do: publish_message(project_id, topic_id, data, %{}, maybe_opts),
      else: publish(project_id, topic_id, [%{data: data, attributes: maybe_opts}], [])
  end

  def publish_message(project_id, topic_id, data, attributes, opts) do
    publish(project_id, topic_id, [%{data: data, attributes: attributes}], opts)
  end

  @common_opts [:timeout, :pool]

  defp common_opts?(list) do
    Keyword.keyword?(list) and Enum.all?(list, fn {key, _} -> key in @common_opts end)
  end

  # Subscriptions

  @doc """
  Creates a subscription to a topic.

  ## Options
  - `:ack_deadline_seconds` - Ack deadline in seconds (10-600, default: 60)
  - [common options](#module-common-options)

  """
  @spec create_subscription(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, subscription()} | {:error, Error.t()}
  def create_subscription(project_id, topic_id, subscription_id, opts \\ []) do
    Telemetry.span(
      :create_subscription,
      %{
        project_id: project_id,
        topic_id: topic_id,
        subscription_id: subscription_id
      },
      fn -> do_create_subscription(project_id, topic_id, subscription_id, opts) end
    )
  end

  defp do_create_subscription(project_id, topic_id, subscription_id, opts) do
    ack_deadline = Keyword.get(opts, :ack_deadline_seconds, 60)

    with {:ok, _} <- Validation.validate_project_id(project_id),
         {:ok, _} <- Validation.validate_topic_id(topic_id),
         {:ok, _} <- Validation.validate_subscription_id(subscription_id),
         {:ok, _} <- Validation.validate_ack_deadline(ack_deadline) do
      request = %PubsubV1.Subscription{
        name: Request.subscription_path(project_id, subscription_id),
        topic: Request.topic_path(project_id, topic_id),
        ack_deadline_seconds: ack_deadline
      }

      fn channel, grpc_opts -> SubscriberStub.create_subscription(channel, request, grpc_opts) end
      |> Request.execute(opts)
      |> Result.unwrap()
    end
  end

  @doc """
  Gets details of a subscription.

  Accepts the [common options](#module-common-options).

  ## Returns
  - `{:ok, %Google.Pubsub.V1.Subscription{}}` on success
  - `{:error, %PubsubGrpc.Error{code: :not_found}}` if subscription doesn't exist

  """
  @spec get_subscription(String.t(), String.t(), keyword()) ::
          {:ok, subscription()} | {:error, Error.t()}
  def get_subscription(project_id, subscription_id, opts \\ []) do
    Telemetry.span(
      :get_subscription,
      %{project_id: project_id, subscription_id: subscription_id},
      fn -> do_get_subscription(project_id, subscription_id, opts) end
    )
  end

  defp do_get_subscription(project_id, subscription_id, opts) do
    with {:ok, _} <- Validation.validate_project_id(project_id),
         {:ok, _} <- Validation.validate_subscription_id(subscription_id) do
      request = %PubsubV1.GetSubscriptionRequest{
        subscription: Request.subscription_path(project_id, subscription_id)
      }

      fn channel, grpc_opts -> SubscriberStub.get_subscription(channel, request, grpc_opts) end
      |> Request.execute(opts)
      |> Result.unwrap()
    end
  end

  @doc """
  Deletes a subscription.

  Accepts the [common options](#module-common-options).

  ## Returns
  - `:ok` on success

  """
  @spec delete_subscription(String.t(), String.t(), keyword()) :: :ok | {:error, Error.t()}
  def delete_subscription(project_id, subscription_id, opts \\ []) do
    Telemetry.span(
      :delete_subscription,
      %{project_id: project_id, subscription_id: subscription_id},
      fn -> do_delete_subscription(project_id, subscription_id, opts) end
    )
  end

  defp do_delete_subscription(project_id, subscription_id, opts) do
    with {:ok, _} <- Validation.validate_project_id(project_id),
         {:ok, _} <- Validation.validate_subscription_id(subscription_id) do
      request = %PubsubV1.DeleteSubscriptionRequest{
        subscription: Request.subscription_path(project_id, subscription_id)
      }

      fn channel, grpc_opts -> SubscriberStub.delete_subscription(channel, request, grpc_opts) end
      |> Request.execute(opts)
      |> Result.unwrap_empty()
    end
  end

  @doc """
  Lists subscriptions in a project.

  ## Options
  - `:page_size` - Maximum number of subscriptions to return
  - `:page_token` - Token for pagination
  - [common options](#module-common-options)

  ## Returns
  - `{:ok, %{subscriptions: [subscription], next_page_token: token}}`

  """
  @spec list_subscriptions(String.t(), keyword()) ::
          {:ok, %{subscriptions: list(), next_page_token: String.t()}} | {:error, Error.t()}
  def list_subscriptions(project_id, opts \\ []) do
    Telemetry.span(:list_subscriptions, %{project_id: project_id}, fn ->
      do_list_subscriptions(project_id, opts)
    end)
  end

  defp do_list_subscriptions(project_id, opts) do
    with {:ok, _} <- Validation.validate_project_id(project_id) do
      request = %PubsubV1.ListSubscriptionsRequest{
        project: Request.project_path(project_id),
        page_size: Keyword.get(opts, :page_size, 0),
        page_token: Keyword.get(opts, :page_token, "")
      }

      fn channel, grpc_opts -> SubscriberStub.list_subscriptions(channel, request, grpc_opts) end
      |> Request.execute(opts)
      |> Result.unwrap_list(:subscriptions, :next_page_token)
    end
  end

  # Message Operations

  @doc """
  Pulls messages from a subscription.

  ## Parameters
  - `max_messages` - Maximum number of messages to pull (default: 10, must be
    positive). Pub/Sub returns at most 1,000 messages per pull.
  - `opts` - [common options](#module-common-options)

  ## Returns
  - `{:ok, [%Google.Pubsub.V1.ReceivedMessage{}]}`

  """
  @spec pull(String.t(), String.t(), pos_integer(), keyword()) ::
          {:ok, list()} | {:error, Error.t()}
  def pull(project_id, subscription_id, max_messages \\ 10, opts \\ []) do
    Telemetry.span(
      :pull,
      %{
        project_id: project_id,
        subscription_id: subscription_id,
        max_messages: max_messages
      },
      fn -> do_pull(project_id, subscription_id, max_messages, opts) end
    )
  end

  defp do_pull(project_id, subscription_id, max_messages, opts) do
    with {:ok, _} <- Validation.validate_project_id(project_id),
         {:ok, _} <- Validation.validate_subscription_id(subscription_id),
         {:ok, _} <- Validation.validate_max_messages(max_messages) do
      request = %PubsubV1.PullRequest{
        subscription: Request.subscription_path(project_id, subscription_id),
        max_messages: max_messages
      }

      fn channel, grpc_opts -> SubscriberStub.pull(channel, request, grpc_opts) end
      |> Request.execute(opts)
      |> case do
        {:ok, {:ok, response}} -> {:ok, response.received_messages}
        other -> Result.unwrap_error(other)
      end
    end
  end

  @doc """
  Acknowledges received messages.

  ## Parameters
  - `ack_ids` - Non-empty list of acknowledgment IDs from received messages, at
    most 512 KiB in total (see [Request limits](#module-request-limits))
  - `opts` - [common options](#module-common-options)

  ## Returns
  - `:ok` on success

  """
  @spec acknowledge(String.t(), String.t(), [String.t()], keyword()) ::
          :ok | {:error, Error.t()}
  def acknowledge(project_id, subscription_id, ack_ids, opts \\ []) do
    ack_count = if is_list(ack_ids), do: length(ack_ids), else: 0

    Telemetry.span(
      :acknowledge,
      %{
        project_id: project_id,
        subscription_id: subscription_id,
        ack_count: ack_count
      },
      fn -> do_acknowledge(project_id, subscription_id, ack_ids, opts) end
    )
  end

  defp do_acknowledge(project_id, subscription_id, ack_ids, opts) do
    with {:ok, _} <- Validation.validate_project_id(project_id),
         {:ok, _} <- Validation.validate_subscription_id(subscription_id),
         {:ok, _} <- Validation.validate_ack_ids(ack_ids) do
      request = %PubsubV1.AcknowledgeRequest{
        subscription: Request.subscription_path(project_id, subscription_id),
        ack_ids: ack_ids
      }

      fn channel, grpc_opts -> SubscriberStub.acknowledge(channel, request, grpc_opts) end
      |> Request.execute(opts)
      |> Result.unwrap_empty()
    end
  end

  @doc """
  Modifies the ack deadline for received messages.

  Setting `ack_deadline_seconds` to 0 causes immediate redelivery (nack).
  Use `nack/3` as a convenience for this.

  ## Parameters
  - `ack_ids` - Non-empty list of acknowledgment IDs, at most 512 KiB in total
  - `ack_deadline_seconds` - New deadline in seconds (0-600)
  - `opts` - [common options](#module-common-options)

  ## Returns
  - `:ok` on success

  """
  @spec modify_ack_deadline(
          String.t(),
          String.t(),
          [String.t()],
          non_neg_integer(),
          keyword()
        ) ::
          :ok | {:error, Error.t()}
  def modify_ack_deadline(project_id, subscription_id, ack_ids, ack_deadline_seconds, opts \\ []) do
    ack_count = if is_list(ack_ids), do: length(ack_ids), else: 0

    Telemetry.span(
      :modify_ack_deadline,
      %{
        project_id: project_id,
        subscription_id: subscription_id,
        ack_count: ack_count,
        ack_deadline_seconds: ack_deadline_seconds
      },
      fn ->
        do_modify_ack_deadline(project_id, subscription_id, ack_ids, ack_deadline_seconds, opts)
      end
    )
  end

  defp do_modify_ack_deadline(project_id, subscription_id, ack_ids, ack_deadline_seconds, opts) do
    with {:ok, _} <- Validation.validate_project_id(project_id),
         {:ok, _} <- Validation.validate_subscription_id(subscription_id),
         {:ok, _} <- Validation.validate_ack_ids(ack_ids),
         {:ok, _} <- Validation.validate_ack_deadline_with_zero(ack_deadline_seconds) do
      request = %PubsubV1.ModifyAckDeadlineRequest{
        subscription: Request.subscription_path(project_id, subscription_id),
        ack_ids: ack_ids,
        ack_deadline_seconds: ack_deadline_seconds
      }

      fn channel, grpc_opts -> SubscriberStub.modify_ack_deadline(channel, request, grpc_opts) end
      |> Request.execute(opts)
      |> Result.unwrap_empty()
    end
  end

  @doc """
  Negatively acknowledges messages, causing immediate redelivery.

  This is a convenience wrapper around `modify_ack_deadline/5` with a deadline of 0.

  ## Parameters
  - `ack_ids` - Non-empty list of acknowledgment IDs
  - `opts` - [common options](#module-common-options)

  ## Returns
  - `:ok` on success

  """
  @spec nack(String.t(), String.t(), [String.t()], keyword()) :: :ok | {:error, Error.t()}
  def nack(project_id, subscription_id, ack_ids, opts \\ []) do
    modify_ack_deadline(project_id, subscription_id, ack_ids, 0, opts)
  end

  # Custom Operations

  @doc """
  Executes a custom gRPC operation using a connection from the pool.

  The function receives a gRPC channel and should return the result of a
  gRPC stub call. `opts` are the [common options](#module-common-options);
  `:timeout` here only bounds the wait for a pool connection (pass a timeout to
  the stub call yourself).

  ## Returns
  - `{:ok, result}` - the callback returned `{:ok, result}`
  - `{:error, %PubsubGrpc.Error{}}` - the callback returned `{:error, reason}`,
    or no connection could be checked out from the pool
  - `{:ok, value}` - the callback returned any other value (e.g. `:ok` or a map)

  ## Examples

      operation = fn channel ->
        request = %Google.Pubsub.V1.GetTopicRequest{topic: "projects/my-project/topics/my-topic"}
        {:ok, auth_opts} = PubsubGrpc.Auth.request_opts(channel)
        Google.Pubsub.V1.Publisher.Stub.get_topic(channel, request, auth_opts)
      end

      {:ok, topic} = PubsubGrpc.execute(operation)

  """
  @spec execute((Client.channel() -> term()), keyword()) ::
          {:ok, term()} | {:error, Error.t()}
  def execute(operation_fn, opts \\ []) when is_function(operation_fn, 1) do
    Client.execute(operation_fn, opts) |> Result.unwrap_any()
  end

  @doc """
  Executes multiple operations using the same connection.

  More efficient when performing several operations in sequence. Return
  values and `opts` are handled the same way as `execute/2`.

  ## Examples

      result = PubsubGrpc.with_connection(fn channel ->
        {:ok, auth_opts} = PubsubGrpc.Auth.request_opts(channel)
        # ... multiple operations on channel
      end)

  """
  @spec with_connection((Client.channel() -> term()), keyword()) ::
          {:ok, term()} | {:error, Error.t()}
  def with_connection(fun, opts \\ []) when is_function(fun, 1) do
    Client.execute(fun, opts) |> Result.unwrap_any()
  end

  # Schema management (delegated)

  @doc """
  Lists schemas in a project.

  ## Options
  - `:view` - `:basic` or `:full` (default: `:basic`)
  - `:page_size` - Maximum number of schemas to return
  - `:page_token` - Token for pagination
  - [common options](#module-common-options)

  """
  defdelegate list_schemas(project_id, opts \\ []), to: Schema

  @doc """
  Gets details of a specific schema.

  ## Options
  - `:view` - `:basic` or `:full` (default: `:full`)
  - [common options](#module-common-options)

  """
  defdelegate get_schema(project_id, schema_id, opts \\ []), to: Schema

  @doc """
  Creates a new schema.

  ## Parameters
  - `type` - `:protocol_buffer` or `:avro`
  - `definition` - The schema definition string
  - `opts` - [common options](#module-common-options)

  """
  defdelegate create_schema(project_id, schema_id, type, definition, opts \\ []), to: Schema

  @doc """
  Deletes a schema.

  Accepts the [common options](#module-common-options).
  """
  defdelegate delete_schema(project_id, schema_id, opts \\ []), to: Schema

  @doc """
  Validates a schema definition.

  Accepts the [common options](#module-common-options).
  """
  defdelegate validate_schema(project_id, type, definition, opts \\ []), to: Schema

  @doc """
  Lists revisions of a schema.

  ## Options
  - `:view` - `:basic` or `:full` (default: `:basic`)
  - `:page_size` - Maximum number of revisions to return
  - `:page_token` - Token for pagination
  - [common options](#module-common-options)

  """
  defdelegate list_schema_revisions(project_id, schema_id, opts \\ []), to: Schema

  @doc """
  Validates a message against an existing schema.

  ## Parameters
  - `schema_name` - Schema ID, or full name `projects/<project>/schemas/<schema_id>`
  - `message` - Message bytes to validate
  - `encoding` - `:json` or `:binary`
  - `opts` - [common options](#module-common-options)

  """
  defdelegate validate_message(project_id, schema_name, message, encoding, opts \\ []),
    to: Schema

  @doc """
  Validates a message against an inline schema definition.

  ## Parameters
  - `type` - `:protocol_buffer` or `:avro`
  - `definition` - Schema definition string
  - `message` - Message bytes to validate
  - `encoding` - `:json` or `:binary`
  - `opts` - [common options](#module-common-options)

  """
  defdelegate validate_message_with_schema(
                project_id,
                type,
                definition,
                message,
                encoding,
                opts \\ []
              ),
              to: Schema
end
