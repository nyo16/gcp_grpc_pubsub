# PubsubGrpc

High-performance Google Cloud Pub/Sub client using gRPC with connection pooling.

[![Hex.pm](https://img.shields.io/hexpm/v/pubsub_grpc.svg)](https://hex.pm/packages/pubsub_grpc)

## Features

- 🚀 **High Performance**: gRPC with connection pooling (2-3x faster than HTTP)
- 📦 **Batch Publishing**: Send 100-1000+ messages per API call
- 🔄 **Auto-Recovery**: Health monitoring with exponential backoff
- 🔐 **Easy Auth**: Goth, gcloud CLI, service accounts, or GCE metadata
- 🐳 **Dev-Friendly**: Docker Compose emulator included
- 📋 **Schema Support**: Protocol Buffer and Avro schemas

## Installation

```elixir
def deps do
  [
    {:pubsub_grpc, "~> 0.3.0"}
  ]
end
```

## Quick Start

### Authentication

```bash
# Option 1: Use gcloud CLI (development)
gcloud auth application-default login

# Option 2: Set service account (production)
export GOOGLE_APPLICATION_CREDENTIALS="/path/to/service-account.json"
```

### Basic Usage

```elixir
# Start IEx
iex -S mix

# Publish messages (single or batch)
{:ok, _} = PubsubGrpc.publish_message("my-project", "my-topic", "Hello!")

messages = [
  %{data: "Order #1", attributes: %{"type" => "order"}},
  %{data: "Order #2", attributes: %{"type" => "order"}},
  %{data: "Order #3", attributes: %{"type" => "order"}}
]
{:ok, response} = PubsubGrpc.publish("my-project", "my-topic", messages)
IO.puts("Published #{length(response.message_ids)} messages")

# Pull and process messages
{:ok, messages} = PubsubGrpc.pull("my-project", "my-subscription", 10)
Enum.each(messages, fn msg -> IO.puts("Received: #{msg.message.data}") end)

# Acknowledge messages
ack_ids = Enum.map(messages, & &1.ack_id)
:ok = PubsubGrpc.acknowledge("my-project", "my-subscription", ack_ids)
```

## Complete Example

```elixir
project_id = "my-project"
topic_id = "events"
subscription_id = "event-processor"

# 1. Create topic and subscription
{:ok, _topic} = PubsubGrpc.create_topic(project_id, topic_id)
{:ok, _sub} = PubsubGrpc.create_subscription(project_id, topic_id, subscription_id)

# 2. Publish batch of messages (much faster than one-by-one!)
messages = Enum.map(1..100, fn i ->
  %{
    data: Jason.encode!(%{event: "user_action", id: i}),
    attributes: %{"source" => "app", "priority" => "high"}
  }
end)
{:ok, _} = PubsubGrpc.publish(project_id, topic_id, messages)

# 3. Pull and process messages
{:ok, received} = PubsubGrpc.pull(project_id, subscription_id, 10)
Enum.each(received, fn msg ->
  data = Jason.decode!(msg.message.data)
  IO.puts("Processing event: #{data["id"]}")
  # Your business logic here
end)

# 4. Acknowledge processed messages
ack_ids = Enum.map(received, & &1.ack_id)
:ok = PubsubGrpc.acknowledge(project_id, subscription_id, ack_ids)

# 5. Check pool health
GrpcConnectionPool.status(PubsubGrpc.ConnectionPool)
# => %{status: :healthy, current_size: 5, expected_size: 5}
```

## Configuration

### Production

```elixir
# config/prod.exs
import Config

# No config needed - uses pubsub.googleapis.com:443
# Set GOOGLE_APPLICATION_CREDENTIALS environment variable
```

### Development (Local Emulator)

```elixir
# config/dev.exs
import Config

config :pubsub_grpc, :emulator,
  project_id: "my-project-id",
  host: "localhost",
  port: 8085
```

Start the emulator:
```bash
docker-compose up -d
```

## API Reference

### Topic Operations

```elixir
# Create topic
{:ok, topic} = PubsubGrpc.create_topic(project_id, topic_id)

# List topics
{:ok, result} = PubsubGrpc.list_topics(project_id)

# Delete topic
:ok = PubsubGrpc.delete_topic(project_id, topic_id)
```

### Publishing

```elixir
# Single message
{:ok, response} = PubsubGrpc.publish_message(project_id, topic_id, "data")
{:ok, response} = PubsubGrpc.publish_message(project_id, topic_id, "data", %{"key" => "value"})

# Batch messages (recommended for performance)
messages = [
  %{data: "message 1", attributes: %{"type" => "order"}},
  %{data: "message 2", attributes: %{"type" => "payment"}}
]
{:ok, response} = PubsubGrpc.publish(project_id, topic_id, messages)
```

### Subscription Operations

```elixir
# Create subscription
{:ok, sub} = PubsubGrpc.create_subscription(project_id, topic_id, subscription_id)
{:ok, sub} = PubsubGrpc.create_subscription(project_id, topic_id, subscription_id,
  ack_deadline_seconds: 30)

# Pull messages
{:ok, messages} = PubsubGrpc.pull(project_id, subscription_id)
{:ok, messages} = PubsubGrpc.pull(project_id, subscription_id, 100)

# Acknowledge messages
ack_ids = Enum.map(messages, & &1.ack_id)
:ok = PubsubGrpc.acknowledge(project_id, subscription_id, ack_ids)

# Delete subscription
:ok = PubsubGrpc.delete_subscription(project_id, subscription_id)
```

### Schema Management

```elixir
# List schemas
{:ok, result} = PubsubGrpc.list_schemas(project_id)

# Get schema
{:ok, schema} = PubsubGrpc.get_schema(project_id, schema_id)

# Create schema
schema_def = """
syntax = "proto3";
message Event {
  string id = 1;
  string type = 2;
}
"""
{:ok, schema} = PubsubGrpc.create_schema(project_id, schema_id, :protocol_buffer, schema_def)

# Validate schema
{:ok, _} = PubsubGrpc.validate_schema(project_id, :protocol_buffer, schema_def)

# Delete schema
:ok = PubsubGrpc.delete_schema(project_id, schema_id)
```

## Performance Tips

### Batch Publishing (5-10x faster)

```elixir
# ❌ Slow: One message at a time
Enum.each(1..100, fn i ->
  PubsubGrpc.publish_message(project_id, topic_id, "Message #{i}")
end)

# ✅ Fast: Batch all messages
messages = Enum.map(1..100, fn i -> %{data: "Message #{i}"} end)
PubsubGrpc.publish(project_id, topic_id, messages)
```

### Connection Pool Monitoring

```elixir
# Check pool health
GrpcConnectionPool.status(PubsubGrpc.ConnectionPool)

# Get a channel directly (advanced)
{:ok, channel} = GrpcConnectionPool.get_channel(PubsubGrpc.ConnectionPool)
```

## Testing

```bash
# Start emulator
docker-compose up -d

# Run tests
mix test

# Stop emulator
docker-compose down
```

## Why gRPC?

- **2-3x better throughput** than HTTP REST API
- **40-60% lower latency** due to persistent connections
- **Efficient binary protocol** (protobuf vs JSON)
- **HTTP/2 multiplexing** over single connection
- **Automatic health monitoring** and recovery

## Advanced Configuration

### Custom Connection Pool

```elixir
# config/prod.exs
config :pubsub_grpc, GrpcConnectionPool,
  endpoint: [
    type: :production,
    host: "pubsub.googleapis.com",
    port: 443,
    ssl: []
  ],
  pool: [
    size: 10,
    name: PubsubGrpc.ConnectionPool
  ],
  connection: [
    keepalive: 30_000,
    ping_interval: 25_000
  ]
```

### Using Goth for Authentication

```elixir
# Add to dependencies
{:goth, "~> 1.4"}

# Configure
config :goth, json: {:system, "GOOGLE_APPLICATION_CREDENTIALS_JSON"}

# Add to supervision tree
{Goth, name: MyApp.Goth, source: {:service_account, credentials}}
```

## Troubleshooting

### Authentication Error

```bash
# Ensure you're authenticated
gcloud auth application-default login

# Or set service account
export GOOGLE_APPLICATION_CREDENTIALS="/path/to/key.json"
```

### Connection Issues

```elixir
# Check pool status
GrpcConnectionPool.status(PubsubGrpc.ConnectionPool)
# Should show: %{status: :healthy, current_size: 5, expected_size: 5}

# Restart application if needed
```

### Emulator Not Working

```bash
# Check if emulator is running
docker ps | grep pubsub

# Restart emulator
docker-compose down
docker-compose up -d

# Check logs
docker-compose logs -f pubsub-emulator
```

## Contributing

1. Fork the repository
2. Start emulator: `docker-compose up -d`
3. Run tests: `mix test`
4. Make changes and ensure tests pass
5. Submit a pull request

## License

MIT

## Links

- [Hex Package](https://hex.pm/packages/pubsub_grpc)
- [Documentation](https://hexdocs.pm/pubsub_grpc)
- [GrpcConnectionPool](https://github.com/nyo16/grpc_connection_pool)
- [Google Cloud Pub/Sub](https://cloud.google.com/pubsub)
