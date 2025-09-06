# PubsubGrpc

A library for interacting with Google Cloud Pub/Sub using gRPC with **NimblePool** connection pooling.

## Features

- 🚀 **Eager Connection Pooling**: All GRPC connections pre-established at startup for zero-latency first requests
- 📦 **Batch Publishing**: High-performance batch message publishing (100-1000+ messages per call)
- 🔐 **Multiple Authentication**: Goth integration, gcloud CLI, service accounts, and GCE metadata
- 🔄 **Auto-Recovery**: Automatic connection health checking and recovery
- 🏊‍♂️ **NimblePool Management**: Efficient connection lifecycle with async initialization
- 🐳 **Docker Support**: Built-in Docker Compose setup for local development
- 🧪 **Comprehensive Tests**: Full integration test suite with emulator
- 🎯 **Clean API**: Simple client interface for common operations

## Why gRPC over HTTP?

This library uses **gRPC** instead of the traditional HTTP REST API for Google Cloud Pub/Sub, providing significant advantages:

### 🚀 **Performance Benefits**
- **HTTP/2 Multiplexing**: Multiple requests over a single connection without head-of-line blocking
- **Binary Protocol**: Efficient protobuf serialization vs JSON, reducing payload size by ~30-60%
- **Connection Reuse**: Persistent connections eliminate TCP handshake overhead for each request
- **Streaming Support**: Built-in support for bidirectional streaming (future enhancement potential)

### ⚡ **Lower Latency**
- **Persistent Connections**: No connection establishment delay per request
- **Header Compression**: HPACK compression reduces redundant header data
- **Native Multiplexing**: Process multiple operations simultaneously over single connection
- **Keep-Alive**: Maintains warm connections preventing cold start delays

### 🛡️ **Reliability & Resilience**
- **Eager Connection Pooling**: All connections pre-established at startup (no lazy initialization delays)
- **NimblePool Management**: Automatic connection lifecycle with async initialization
- **Health Checking**: Automatic detection and recovery from dead connections
- **Timeout Handling**: Built-in keepalive prevents Google's 1-minute idle timeout  
- **Exponential Backoff**: Smart retry logic for connection failures

### 📊 **Practical Impact**
```elixir
# HTTP REST API (typical)
# - New connection per request
# - JSON serialization overhead  
# - No connection reuse
# - Higher memory usage per request

# This gRPC Implementation
# - Pooled persistent connections
# - Efficient protobuf serialization
# - Connection multiplexing
# - Lower memory footprint
```

**Benchmark expectations**: 2-3x better throughput and 40-60% lower latency compared to HTTP implementations, especially under high load scenarios.

## Installation

Add `pubsub_grpc` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:pubsub_grpc, "~> 0.2.0"}
  ]
end
```

## Usage

### Simple API (Recommended)

The main `PubsubGrpc` module provides convenient functions for common operations:

#### 1. Creating a Topic

```elixir
{:ok, topic} = PubsubGrpc.create_topic("my-project", "events")
```

#### 2. Publishing Messages

##### Batch Publishing (Recommended for High Throughput)

```elixir
# Publish multiple messages in a single API call - much more efficient!
messages = [
  %{data: "Order created", attributes: %{"type" => "order", "user_id" => "123"}},
  %{data: "Payment processed", attributes: %{"type" => "payment", "amount" => "99.99"}},
  %{data: "Email sent", attributes: %{"type" => "notification", "template" => "receipt"}}
]
{:ok, response} = PubsubGrpc.publish("my-project", "events", messages)
IO.inspect(response.message_ids)  # ["msg_id_1", "msg_id_2", "msg_id_3"]
```

**Performance Benefits:**
- 🚀 **Higher Throughput**: Send 100-1000+ messages per API call
- ⚡ **Lower Latency**: Single network round-trip instead of N calls  
- 💰 **Cost Efficient**: Fewer API calls = lower costs
- 🔗 **Connection Reuse**: One connection checkout from pool

##### Single Message Publishing

```elixir
# Publish single message (convenience function)
{:ok, response} = PubsubGrpc.publish_message("my-project", "events", "Hello!")
{:ok, response} = PubsubGrpc.publish_message("my-project", "events", "Hello!", %{"source" => "app"})
```

#### 3. Creating a Subscription

```elixir
{:ok, subscription} = PubsubGrpc.create_subscription("my-project", "events", "my-subscription")

# With custom acknowledgment deadline
{:ok, subscription} = PubsubGrpc.create_subscription("my-project", "events", "my-subscription", 
  ack_deadline_seconds: 30)
```

#### 4. Pulling Messages

```elixir
# Pull up to 10 messages (default)
{:ok, messages} = PubsubGrpc.pull("my-project", "my-subscription")

# Pull specific number of messages
{:ok, messages} = PubsubGrpc.pull("my-project", "my-subscription", 5)

# Process messages
Enum.each(messages, fn msg ->
  IO.puts("Received: #{msg.message.data}")
  IO.inspect(msg.message.attributes)
end)
```

#### 5. Acknowledging Messages

```elixir
{:ok, messages} = PubsubGrpc.pull("my-project", "my-subscription")

# Extract acknowledgment IDs
ack_ids = Enum.map(messages, & &1.ack_id)

# Acknowledge processed messages
:ok = PubsubGrpc.acknowledge("my-project", "my-subscription", ack_ids)
```

#### 6. Complete Workflow Example

```elixir
# Complete pub/sub workflow
{:ok, _topic} = PubsubGrpc.create_topic("my-project", "events")
{:ok, _subscription} = PubsubGrpc.create_subscription("my-project", "events", "processor")

# Publish some messages
messages = [
  %{data: "Event 1", attributes: %{"type" => "user_signup"}},
  %{data: "Event 2", attributes: %{"type" => "user_login"}}
]
{:ok, _response} = PubsubGrpc.publish("my-project", "events", messages)

# Process messages
{:ok, received_messages} = PubsubGrpc.pull("my-project", "processor", 10)

Enum.each(received_messages, fn msg ->
  # Process the message
  IO.puts("Processing: #{msg.message.data}")
  process_event(msg.message.data, msg.message.attributes)
end)

# Acknowledge processed messages
ack_ids = Enum.map(received_messages, & &1.ack_id)
:ok = PubsubGrpc.acknowledge("my-project", "processor", ack_ids)
```

### Advanced API (Lower Level)

For more complex operations, you can use the lower-level client API:

```elixir
# Custom operation using Client.execute
operation = fn channel, _params ->
  request = %Google.Pubsub.V1.GetTopicRequest{topic: "projects/my-project/topics/my-topic"}
  Google.Pubsub.V1.Publisher.Stub.get_topic(channel, request)
end

{:ok, topic} = PubsubGrpc.Client.execute(operation)

# Multiple operations with same connection
result = PubsubGrpc.with_connection(fn channel ->
  # Create topic
  topic_request = %Google.Pubsub.V1.Topic{
    name: "projects/my-project/topics/batch-topic"
  }
  {:ok, _topic} = Google.Pubsub.V1.Publisher.Stub.create_topic(channel, topic_request)
  
  # Publish message
  message = %Google.Pubsub.V1.PubsubMessage{data: "Batch operation"}
  publish_request = %Google.Pubsub.V1.PublishRequest{
    topic: "projects/my-project/topics/batch-topic",
    messages: [message]
  }
  Google.Pubsub.V1.Publisher.Stub.publish(channel, publish_request)
end)
```

### Configuration

#### Production (Google Cloud)

For production use with Google Cloud, you need to set up authentication. See the [Authentication](#authentication) section below.

```elixir
# config/prod.exs
import Config

# No additional config needed - will connect to pubsub.googleapis.com:443
# Authentication is handled via environment variables or service account keys
```

#### Development/Test (Local Emulator)

```elixir
# config/dev.exs and config/test.exs
import Config

config :pubsub_grpc, :emulator,
  project_id: "my-project-id",
  host: "localhost",
  port: 8085
```

## Authentication

For production use with Google Cloud Pub/Sub, you need to authenticate your application. **This library automatically handles authentication** when you set up credentials using any of the methods below - no additional code changes are needed in your application.

The library supports multiple authentication methods:

### Method 1: Service Account Key (Recommended for Production)

1. **Create a Service Account:**
   - Go to the [Google Cloud Console](https://console.cloud.google.com/)
   - Navigate to IAM & Admin > Service Accounts
   - Create a new service account with Pub/Sub permissions
   - Download the JSON key file

2. **Set Environment Variable:**
   ```bash
   export GOOGLE_APPLICATION_CREDENTIALS="/path/to/service-account-key.json"
   ```

3. **Use in Production:**
   ```elixir
   # Your application will automatically use the credentials
   {:ok, topic} = PubsubGrpc.create_topic("my-project", "my-topic")
   
   # The library automatically handles authentication through the GRPC SSL credentials
   # No additional configuration needed - just ensure GOOGLE_APPLICATION_CREDENTIALS is set
   ```

### Method 2: Using Goth Library (Advanced Token Control)

If you need explicit control over token management, you can use the [Goth](https://github.com/peburrows/goth) library for custom authentication handling:

1. **Add Goth to your dependencies:**
   ```elixir
   def deps do
     [
       {:pubsub_grpc, "~> 0.2.0"},
       {:goth, "~> 1.3"}
     ]
   end
   ```

2. **Configure Goth in your application:**
   ```elixir
   # config/prod.exs
   config :goth, json: {:system, "GOOGLE_APPLICATION_CREDENTIALS_JSON"}

   # lib/my_app/application.ex
   def start(_type, _args) do
     children = [
       {Goth, name: MyApp.Goth, source: {:service_account, credentials}},
       # ... other children
     ]
   end
   ```

3. **Manual token handling with low-level GRPC (for advanced use cases):**
   ```elixir
   # Get token from Goth
   {:ok, %{token: token, type: type}} = Goth.fetch(MyApp.Goth)
   
   # Direct GRPC connection with explicit token
   project_id = "my-project-id"
   {:ok, channel} = GRPC.Stub.connect("pubsub.googleapis.com:443", 
     cred: GRPC.Credential.new(ssl: []))
   
   req = %Google.Pubsub.V1.ListTopicsRequest{
     project: "projects/#{project_id}", 
     page_size: 5
   }
   
   {:ok, reply} = channel 
   |> Google.Pubsub.V1.Publisher.Stub.list_topics(
        req, 
        metadata: %{"authorization" => "#{type} #{token}"},
        content_type: "application/grpc"
      )
   
   # Note: The main PubsubGrpc API automatically handles authentication
   # This manual approach is only needed for custom GRPC operations
   ```

### Method 3: Default Application Credentials

If running on Google Cloud (GCE, GKE, Cloud Functions, etc.), credentials are automatically available:

```elixir
# No additional configuration needed when running on Google Cloud
# The library automatically detects and uses the default credentials
{:ok, topic} = PubsubGrpc.create_topic("my-project", "my-topic")
```

### Method 4: Development with gcloud CLI

For development, you can use gcloud authentication:

```bash
# Authenticate with your Google account
gcloud auth application-default login

# Your application will use these credentials automatically
```

### Authentication Notes

- **Emulator**: No authentication required when using the local emulator
- **Production**: Always use service account keys or default application credentials
- **Permissions**: Ensure your service account has the necessary Pub/Sub permissions:
  - `pubsub.topics.create`, `pubsub.topics.delete`, `pubsub.topics.list`
  - `pubsub.subscriptions.create`, `pubsub.subscriptions.delete`
  - `pubsub.messages.publish`, `pubsub.messages.pull`, `pubsub.messages.ack`

## Examples

The `lib/pubsub_grpc/example.ex` file contains comprehensive examples:

```elixir
# Create a topic
{:ok, topic} = PubsubGrpc.Example.create_topic_example("my-project-id", "example-topic")

# Publish messages
messages = ["Hello", "World", "from", "Elixir"]
{:ok, response} = PubsubGrpc.Example.publish_example("my-project-id", "example-topic", messages)

# Complex workflow with error handling
{:ok, result} = PubsubGrpc.Example.complex_operation_example("my-project-id", "workflow-topic")
```

## Testing

The project includes comprehensive integration tests that work with the Docker Compose emulator:

```bash
# Run all tests (starts emulator automatically)
mix test

# Run only connection pool tests
mix test --include connection_pool

# Run only integration tests with emulator
mix test --include integration
```

## Development with Pub/Sub Emulator

This project includes a Docker Compose configuration for running a local Google Cloud Pub/Sub emulator.

### Quick Start

```bash
# 1. Start the emulator
docker-compose up -d

# 2. Run your application in development
mix run

# 3. Run tests with emulator
mix test --include integration

# 4. Stop the emulator when done
docker-compose down
```

### Starting the Emulator

To start the Pub/Sub emulator:

```bash
docker-compose up -d
```

This will start the emulator in the background. The emulator will be available at `localhost:8085`.

### Stopping the Emulator

To stop the emulator:

```bash
docker-compose down
```

### Configuration

The emulator is configured to use the project ID `my-project-id`. This matches the configuration in `config/dev.exs`.

When running in development mode, the application will automatically connect to the local emulator instead of the real Google Cloud Pub/Sub service.

### Viewing Logs

To view the emulator logs:

```bash
docker-compose logs -f pubsub-emulator
```

## Connection Pooling

### Default Pool

PubsubGrpc automatically starts a connection pool (`PubsubGrpc.ConnectionPool`) with 5 connections when the application starts. All the convenience functions use this default pool.

### Custom Pools

You can create additional pools for different use cases:

#### 1. Adding to Supervision Tree

```elixir
# lib/my_app/application.ex
defmodule MyApp.Application do
  use Application

  def start(_type, _args) do
    children = [
      # Your other services...
      
      # Custom Pub/Sub pool for high-throughput operations
      {PubsubGrpc.Connection, [
        name: MyApp.HighThroughputPool,
        pool_size: 20
      ]},
      
      # Custom pool for background jobs
      {PubsubGrpc.Connection, [
        name: MyApp.BackgroundJobsPool,
        pool_size: 3
      ]},
      
      # Pool with custom connection options
      {PubsubGrpc.Connection, [
        name: MyApp.CustomPool,
        pool_size: 10,
        emulator: [project_id: "custom-project", host: "localhost", port: 8086]
      ]}
    ]

    opts = [strategy: :one_for_one, name: MyApp.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
```

#### 2. Using Custom Pools

```elixir
# Using the high-throughput pool
operation = fn channel, _params ->
  request = %Google.Pubsub.V1.Topic{name: "projects/my-project/topics/high-volume"}
  Google.Pubsub.V1.Publisher.Stub.create_topic(channel, request)
end

{:ok, topic} = PubsubGrpc.Connection.execute(MyApp.HighThroughputPool, operation)

# Or using the Client module
{:ok, topic} = PubsubGrpc.Client.execute(MyApp.HighThroughputPool, operation)
```

#### 3. Runtime Pool Creation

```elixir
# Start a pool dynamically
{:ok, pid} = PubsubGrpc.Connection.start_link([
  name: MyApp.DynamicPool,
  pool_size: 8
])

# Use the dynamic pool
operation = fn channel, _params ->
  # Your GRPC operation here
end

{:ok, result} = PubsubGrpc.Connection.execute(MyApp.DynamicPool, operation)
```

### Pool Configuration Options

```elixir
{PubsubGrpc.Connection, [
  # Required: Pool name (must be unique)
  name: MyApp.MyPool,
  
  # Optional: Number of connections in the pool (default: 5)
  pool_size: 10,
  
  # Optional: Override emulator settings for this pool
  emulator: [
    project_id: "test-project",
    host: "localhost", 
    port: 8085
  ],
  
  # Optional: SSL options for production (default: [])
  ssl_opts: []
]}
```

### Pool Monitoring and Health

```elixir
# Check if pool is alive
Process.alive?(Process.whereis(MyApp.MyPool))

# Get pool information (NimblePool specific)
:sys.get_status(MyApp.MyPool)
```

### Pool Best Practices

#### 1. Pool Sizing

```elixir
# For high-throughput applications
{PubsubGrpc.Connection, [name: MyApp.HighVolumePool, pool_size: 20]}

# For background processing
{PubsubGrpc.Connection, [name: MyApp.BackgroundPool, pool_size: 5]}

# For real-time operations
{PubsubGrpc.Connection, [name: MyApp.RealtimePool, pool_size: 10]}
```

#### 2. Separate Pools by Function

```elixir
children = [
  # Publisher pool - optimized for publishing
  {PubsubGrpc.Connection, [
    name: MyApp.PublisherPool,
    pool_size: 15
  ]},
  
  # Subscriber pool - optimized for pulling
  {PubsubGrpc.Connection, [
    name: MyApp.SubscriberPool,  
    pool_size: 8
  ]},
  
  # Admin pool - for topic/subscription management
  {PubsubGrpc.Connection, [
    name: MyApp.AdminPool,
    pool_size: 3
  ]}
]
```

#### 3. Using Pools in GenServers

```elixir
defmodule MyApp.PubSubWorker do
  use GenServer
  
  # Use specific pool for this worker
  @pool_name MyApp.WorkerPool
  
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end
  
  def publish_event(data) do
    GenServer.cast(__MODULE__, {:publish, data})
  end
  
  def handle_cast({:publish, data}, state) do
    operation = fn channel, _params ->
      message = %Google.Pubsub.V1.PubsubMessage{data: data}
      request = %Google.Pubsub.V1.PublishRequest{
        topic: state.topic_path,
        messages: [message]
      }
      Google.Pubsub.V1.Publisher.Stub.publish(channel, request)
    end
    
    # Use dedicated pool
    case PubsubGrpc.Connection.execute(@pool_name, operation) do
      {:ok, _response} -> 
        IO.puts("Published successfully")
      {:error, error} -> 
        IO.puts("Failed to publish: #{inspect(error)}")
    end
    
    {:noreply, state}
  end
end

# Add both the pool and worker to supervision tree
children = [
  {PubsubGrpc.Connection, [name: MyApp.WorkerPool, pool_size: 5]},
  {MyApp.PubSubWorker, [topic_path: "projects/my-project/topics/events"]}
]
```

## Architecture

- **NimblePool**: Manages a pool of GRPC connections efficiently
- **Lazy Connections**: Connections are created only when needed
- **Health Checking**: Automatically detects and replaces dead connections
- **Error Recovery**: Graceful handling of network failures and reconnection
- **Docker Integration**: Seamless development with local emulator

## Quick Start Examples

### IEx Testing Pattern

```elixir
# Start the emulator first
# docker-compose up -d

# Start IEx
# iex -S mix

# Use unique names to avoid conflicts
timestamp = :os.system_time(:millisecond)
topic_name = "test-topic-#{timestamp}"
sub_name = "test-sub-#{timestamp}"

# Create resources
{:ok, topic} = PubsubGrpc.create_topic("test-project", topic_name)
{:ok, subscription} = PubsubGrpc.create_subscription("test-project", topic_name, sub_name)

# Publish and pull messages
{:ok, _} = PubsubGrpc.publish_message("test-project", topic_name, "Hello World!")

# Important: Wait for message delivery (Pub/Sub is asynchronous)
:timer.sleep(1000)

# Pull messages with retry helper
pull_with_retry = fn project, sub, max_attempts ->
  Enum.reduce_while(1..max_attempts, [], fn _attempt, acc ->
    case PubsubGrpc.pull(project, sub, 10) do
      {:ok, []} when acc == [] -> :timer.sleep(500); {:cont, acc}
      {:ok, msgs} -> {:halt, acc ++ msgs}
    end
  end)
end

messages = pull_with_retry.("test-project", sub_name, 5)
IO.puts("Received #{length(messages)} messages")

# Always acknowledge messages (this tells Pub/Sub you processed them)
if length(messages) > 0 do
  ack_ids = Enum.map(messages, & &1.ack_id)
  :ok = PubsubGrpc.acknowledge("test-project", sub_name, ack_ids)
  IO.puts("✅ Acknowledged #{length(ack_ids)} messages")
end

# Cleanup
:ok = PubsubGrpc.delete_subscription("test-project", sub_name)
:ok = PubsubGrpc.delete_topic("test-project", topic_name)
```

### Error Handling

```elixir
# Handle existing resources gracefully
case PubsubGrpc.create_topic("test-project", "existing-topic") do
  {:ok, topic} -> IO.puts("Created: #{topic.name}")
  {:error, %GRPC.RPCError{status: 6}} -> IO.puts("Topic already exists")
  {:error, reason} -> IO.puts("Error: #{inspect(reason)}")
end
```

### Function Return Types

- **Returns `{:ok, data}`**: `create_topic/2`, `list_topics/1`, `publish/3`, `publish_message/3,4`, `create_subscription/3,4`, `pull/3`
- **Returns `:ok`**: `delete_topic/2`, `delete_subscription/2`, `acknowledge/3`

### Message Acknowledgment

**What is acknowledgment?** When you pull messages from a subscription, you must acknowledge them to tell Pub/Sub you've successfully processed them. Unacknowledged messages will be redelivered.

```elixir
# 1. Pull messages
{:ok, messages} = PubsubGrpc.pull("test-project", "my-sub", 10)

# 2. Process your messages here
Enum.each(messages, fn msg ->
  IO.puts("Processing: #{msg.message.data}")
  # Your business logic here...
end)

# 3. Extract ack_ids from messages
ack_ids = Enum.map(messages, & &1.ack_id)

# 4. Acknowledge to prevent redelivery
:ok = PubsubGrpc.acknowledge("test-project", "my-sub", ack_ids)
```

**Important**: If you don't acknowledge messages, they will be redelivered after the `ack_deadline_seconds` expires (default 10 seconds).

## Contributing

1. Start the emulator: `docker-compose up -d`
2. Install dependencies: `mix deps.get`
3. Run tests: `mix test`
4. Make your changes
5. Ensure tests pass: `mix test --include integration`
6. Submit a pull request
