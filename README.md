# PubsubGrpc

High-performance Google Cloud Pub/Sub client using gRPC with connection pooling.

[![Hex.pm](https://img.shields.io/hexpm/v/pubsub_grpc.svg)](https://hex.pm/packages/pubsub_grpc)

## Features

- 🚀 **High Performance**: gRPC with connection pooling (2-3x faster than HTTP)
- 📦 **Batch Publishing**: Send 100-1000+ messages per API call
- 🔄 **Auto-Recovery**: Health monitoring with exponential backoff
- 🔐 **Auth**: Goth (service accounts, GCE/GKE metadata) or the gcloud CLI for development
- 🐳 **Dev-Friendly**: Docker Compose emulator included
- 📋 **Schema Support**: Protocol Buffer and Avro schemas

## Installation

```elixir
def deps do
  [
    {:pubsub_grpc, "~> 0.7.0"}
  ]
end
```

**Requirements:** Elixir ≥ 1.19 and Erlang/OTP ≥ 28. CI runs Elixir 1.19 on OTP 28 and
Elixir 1.20 on OTP 29.1.

## Quick Start

### Authentication

Production: use [Goth](#using-goth-for-authentication) and set
`config :pubsub_grpc, :goth, MyApp.Goth`. Development without Goth: the library falls
back to the gcloud CLI (it forks `gcloud` on every token refresh, so do not use it in
production):

```bash
gcloud auth application-default login
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
PubsubGrpc.pool_status()
# => %{status: :healthy, current_size: 5, expected_size: 5, ...}
```

## Configuration

### Production

```elixir
# config/prod.exs
import Config

# Endpoint: pubsub.googleapis.com:443 with verified TLS, no config needed.
# Credentials: Goth (see "Using Goth for Authentication").
config :pubsub_grpc, :goth, MyApp.Goth
```

### Development (Local Emulator)

```elixir
# config/dev.exs
import Config

config :pubsub_grpc, :emulator, host: "localhost", port: 8085
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
# Check pool health (pass pool: name for another pool)
PubsubGrpc.pool_status()

# Custom gRPC call on a pooled channel (advanced): errors are normalized to
# %PubsubGrpc.Error{}, and the auth token is attached only over TLS
alias PubsubGrpc.Proto.Google.Pubsub.V1

{:ok, topic} =
  PubsubGrpc.execute(fn channel ->
    {:ok, auth_opts} = PubsubGrpc.Auth.request_opts(channel)
    request = %V1.GetTopicRequest{topic: "projects/#{project_id}/topics/#{topic_id}"}
    V1.Publisher.Stub.get_topic(channel, request, auth_opts)
  end)
```

### Pool Size and Long Polling

The pool has 5 connections by default. grpc serializes request starts per connection
process, and `pull/4` on an empty subscription can hold a connection until messages
arrive or the deadline passes (up to its `:timeout`, 30 s by default). Size the pool to
at least your number of concurrent pulls plus headroom for other calls, and pass a pull
`:timeout` below any `GenServer.call` timeout that wraps it:

```elixir
config :pubsub_grpc, :default_pool_size, 10
# or: config :pubsub_grpc, GrpcConnectionPool, pool: [size: 10], ...
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
    port: 443
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

Production endpoints use verified TLS by default (system CA store, peer and hostname
verification), so no `ssl:` key is needed. To customise TLS, set options that are merged
over those defaults:

```elixir
config :pubsub_grpc, :ssl_opts, versions: [:"tlsv1.3"]
```

### Supervising the Pool Yourself

By default the `:pubsub_grpc` application starts the connection pool. To start it in your
own supervision tree instead (e.g. to control start order), disable the built-in pool and
add `PubsubGrpc` as a child (see `PubsubGrpc.child_spec/1`). It reads the same pool
configuration as the built-in one:

```elixir
# config/config.exs
config :pubsub_grpc, :start_pool, false

# MyApp.Application
children = [
  PubsubGrpc,
  # ... processes that use PubsubGrpc
]
```

### Auth Timeout

A token fetch (Goth or gcloud CLI) that takes longer than `:auth_timeout` milliseconds
(default `10_000`) is aborted and callers get
`{:error, %PubsubGrpc.Error{code: :deadline_exceeded}}`:

```elixir
config :pubsub_grpc, :auth_timeout, 5_000
```

### Using Goth for Authentication

Goth is the supported production auth source. It covers service account keys and the
GCE/GKE metadata server; tokens are cached and refreshed in the background before they
expire.

```elixir
# mix.exs
{:goth, "~> 1.4"}

# config/config.exs
config :pubsub_grpc, :goth, MyApp.Goth

# MyApp.Application: service account key from an env var holding the JSON
credentials = "GOOGLE_APPLICATION_CREDENTIALS_JSON" |> System.fetch_env!() |> Jason.decode!()

children = [
  {Goth, name: MyApp.Goth, source: {:service_account, credentials}}
  # On GCE/GKE use the metadata server instead:
  # {Goth, name: MyApp.Goth, source: {:metadata, []}}
]
```

`GOOGLE_APPLICATION_CREDENTIALS` (a key file path) is not read by this library directly;
load the file and pass it to Goth: `credentials = path |> File.read!() |> Jason.decode!()`.

Without `:goth`, tokens come from `gcloud auth application-default print-access-token`.
That forks a process per refresh and is meant for development only.

## Security Advisories

`mix hex.audit` in a project depending on `pubsub_grpc` reports CVE-2026-43966 for
**cowlib** (EEF-CVE-2026-43966) and **gun** (GHSA-w4f7-4cxr-rv3c). Both come in through
grpc's gun adapter, and neither is reachable from this library:

- cowlib: the vulnerable encoder `cow_http_struct_hd:escape_string/2` is not called on the
  gRPC client path. No fixed cowlib release exists yet.
- gun: the advisory's "patched" version (2.16.0) is a cowboy version, so scanners flag
  every gun release. grpc pins `gun ~> 2.4.0`.

This library ignores the advisory in its own `mix.exs`; to do the same in yours:

```elixir
def project do
  [
    # ...
    hex: [ignore_advisories: ["CVE-2026-43966"]]
  ]
end
```

Review the list on every dependency bump. Since 0.8.0 (via `grpc_connection_pool`
0.5.5), updating `pubsub_grpc` enforces the fixed cowlib (≥ 2.21.0) and protobuf
(≥ 0.17.1). If you use Goth, also make sure your lock has jose ≥ 1.11.13:

```bash
mix deps.update pubsub_grpc jose
```

## Troubleshooting

### Authentication Error

```bash
# Development: authenticate the gcloud CLI
gcloud auth application-default login

# Production: check that `config :pubsub_grpc, :goth, MyApp.Goth` is set and the
# Goth process is started before the first call
```

### Connection Issues

```elixir
# Check pool status
PubsubGrpc.pool_status()
# Should show: %{status: :healthy, current_size: 5, expected_size: 5, ...}

# Restart application if needed
```

### Emulator Not Working

```bash
# Run all tests (starts emulator automatically)
mix test

# Run only connection pool tests
mix test --include connection_pool

# Run only integration tests with emulator
mix test --include integration
```

## Development with Pub/Sub Emulator

This project includes multiple ways to run a local Google Cloud Pub/Sub emulator for development and testing.

The `mix emulator.*` tasks live in `dev/mix/tasks/` and are compiled only in the `:dev` and
`:test` environments of a checkout of this repository. They are not part of the Hex
package, so projects that depend on `pubsub_grpc` should use Docker Compose or the Docker
command below.

### Quick Start

#### Using Mix Commands (Recommended)

```bash
# 1. Start the emulator
mix emulator.start

# 2. Run your application in development
mix run

# 3. Run tests with emulator
mix test --include integration

# 4. Stop the emulator when done
mix emulator.stop
```

#### Using Docker Compose

```bash
# 1. Start the emulator
docker-compose up -d

# 2. Run your application in development
mix run

# Restart emulator
docker-compose down
```

#### Using Docker Command Directly

```bash
# Start the emulator
docker run --rm -p 127.0.0.1:8085:8085 google/cloud-sdk:489.0.0-emulators@sha256:6e0520e94bf93e4f4d53ffd8f52b664bd614b73e2f2e8467f54f6c9a9f4d0763 /bin/bash -c "gcloud beta emulators pubsub start --project=test-project-id --host-port='0.0.0.0:8085'"

# Stop with Ctrl+C or docker stop
```

### Mix Commands (repository checkout only)

A checkout of this repository provides Mix tasks for emulator management
(`dev/mix/tasks/`, not shipped in the Hex package):

#### `mix emulator.start`
- Starts the Google Cloud Pub/Sub emulator in a Docker container
- Uses project ID `test-project-id`
- Runs on port 8085
- Container is named `pubsub-emulator` for easy management
- Checks if emulator is already running to avoid conflicts

#### `mix emulator.stop`
- Stops the running emulator container
- Safe to run even if emulator is not running

#### Usage Examples

```bash
# Check if emulator is already running
mix emulator.start
# Output: "Emulator is already running" or "Emulator started successfully on port 8085"

# Stop the emulator
mix emulator.stop
# Output: "Emulator stopped successfully" or "Emulator is not running"
```

### Starting the Emulator

#### Method 1: Mix Command (Recommended)
```bash
mix emulator.start
```

#### Method 2: Docker Compose
```bash
docker-compose up -d
```

#### Method 3: Direct Docker Command
```bash
docker run --rm -p 127.0.0.1:8085:8085 google/cloud-sdk:489.0.0-emulators@sha256:6e0520e94bf93e4f4d53ffd8f52b664bd614b73e2f2e8467f54f6c9a9f4d0763 /bin/bash -c "gcloud beta emulators pubsub start --project=test-project-id --host-port='0.0.0.0:8085'"
```

All methods start the emulator at `localhost:8085` with project ID `test-project-id`.

### Stopping the Emulator

#### Method 1: Mix Command
```bash
mix emulator.stop
```

#### Method 2: Docker Compose
```bash
docker-compose down
```

#### Method 3: Direct Docker (if started with docker run)
- Use Ctrl+C to stop
- Or `docker stop <container_id>`

### Viewing Logs

```bash
docker-compose logs -f pubsub-emulator
```

## Contributing

1. Fork the repository
2. Start emulator: `docker-compose up -d`
3. Run tests: `mix test`
4. Make changes and ensure tests pass
5. Submit a pull request

## License

Apache-2.0 — see [LICENSE](LICENSE).

## Links

- [Hex Package](https://hex.pm/packages/pubsub_grpc)
- [Documentation](https://hexdocs.pm/pubsub_grpc)
- [GrpcConnectionPool](https://github.com/nyo16/grpc_connection_pool)
- [Google Cloud Pub/Sub](https://cloud.google.com/pubsub)
