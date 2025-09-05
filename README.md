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

### Basic Operations

#### 1. Creating a Topic

```elixir
# Create a topic
create_topic_operation = fn channel, _params ->
  request = %Google.Pubsub.V1.Topic{
    name: "projects/my-project-id/topics/my-topic"
  }
  Google.Pubsub.V1.Publisher.Stub.create_topic(channel, request)
end

{:ok, topic} = PubsubGrpc.Client.execute(create_topic_operation)
```

#### 2. Publishing Messages

```elixir
# Publish a single message
publish_operation = fn channel, _params ->
  message = %Google.Pubsub.V1.PubsubMessage{
    data: "Hello, Pub/Sub!",
    attributes: %{"source" => "my_app"}
  }

  request = %Google.Pubsub.V1.PublishRequest{
    topic: "projects/my-project-id/topics/my-topic",
    messages: [message]
  }

  Google.Pubsub.V1.Publisher.Stub.publish(channel, request)
end

{:ok, response} = PubsubGrpc.Client.execute(publish_operation)
```

#### 3. Creating a Subscription

```elixir
# Create a subscription
create_subscription_operation = fn channel, _params ->
  request = %Google.Pubsub.V1.Subscription{
    name: "projects/my-project-id/subscriptions/my-subscription",
    topic: "projects/my-project-id/topics/my-topic",
    ack_deadline_seconds: 60
  }
  Google.Pubsub.V1.Subscriber.Stub.create_subscription(channel, request)
end

{:ok, subscription} = PubsubGrpc.Client.execute(create_subscription_operation)
```

#### 4. Pulling Messages

```elixir
# Pull messages from subscription
pull_operation = fn channel, _params ->
  request = %Google.Pubsub.V1.PullRequest{
    subscription: "projects/my-project-id/subscriptions/my-subscription",
    max_messages: 10
  }
  Google.Pubsub.V1.Subscriber.Stub.pull(channel, request)
end

{:ok, response} = PubsubGrpc.Client.execute(pull_operation)
```

#### 5. Acknowledging Messages

```elixir
# Acknowledge processed messages
acknowledge_operation = fn channel, ack_ids ->
  request = %Google.Pubsub.V1.AcknowledgeRequest{
    subscription: "projects/my-project-id/subscriptions/my-subscription",
    ack_ids: ack_ids
  }
  Google.Pubsub.V1.Subscriber.Stub.acknowledge(channel, request)
end

:ok = PubsubGrpc.Client.execute(acknowledge_operation, ["ack-id-1", "ack-id-2"])
```

### Using Connection Pool Directly

```elixir
# Execute multiple operations with the same connection
result = PubsubGrpc.Client.with_connection(fn channel ->
  # Create topic
  topic_request = %Google.Pubsub.V1.Topic{
    name: "projects/my-project-id/topics/batch-topic"
  }
  {:ok, _topic} = Google.Pubsub.V1.Publisher.Stub.create_topic(channel, topic_request)
  
  # Publish message
  message = %Google.Pubsub.V1.PubsubMessage{data: "Batch operation"}
  publish_request = %Google.Pubsub.V1.PublishRequest{
    topic: "projects/my-project-id/topics/batch-topic",
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

## Connection Pool Configuration

You can configure the connection pool settings in your application:

```elixir
# In your application.ex or supervision tree
children = [
  {PubsubGrpc.Connection, [
    name: MyApp.PubSubPool,
    pool_size: 10  # Default: 5
  ]}
]

# Use custom pool
PubsubGrpc.Connection.execute(MyApp.PubSubPool, operation_fn)
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
