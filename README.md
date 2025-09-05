# PubsubGrpc

A library for interacting with Google Cloud Pub/Sub using gRPC with **NimblePool** connection pooling.

## Features

- 🏊‍♂️ **Connection Pooling**: Uses NimblePool for efficient GRPC connection management
- 🔄 **Auto-Recovery**: Automatic connection health checking and recovery
- 🐳 **Docker Support**: Built-in Docker Compose setup for local development
- 🧪 **Comprehensive Tests**: Full integration test suite with emulator
- 🎯 **Clean API**: Simple client interface for common operations

## Installation

Add `pubsub_grpc` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:pubsub_grpc, "~> 0.1.0"}
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

```elixir
# Publish multiple messages
messages = [
  %{data: "Hello World", attributes: %{"source" => "app"}},
  %{data: "Another message"}
]
{:ok, response} = PubsubGrpc.publish("my-project", "events", messages)

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

```elixir
# config/prod.exs
import Config

# Will connect to pubsub.googleapis.com:443
# Make sure to set up authentication (service account, gcloud, etc.)
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

## Contributing

1. Start the emulator: `docker-compose up -d`
2. Install dependencies: `mix deps.get`
3. Run tests: `mix test`
4. Make your changes
5. Ensure tests pass: `mix test --include integration`
6. Submit a pull request
