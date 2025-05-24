# PubsubGrpc

A library for interacting with Google Cloud Pub/Sub using gRPC.

## Installation

If [available in Hex](https://hex.pm/docs/publish), the package can be installed
by adding `pubsub_grpc` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:pubsub_grpc, "~> 0.1.0"}
  ]
end
```

Documentation can be generated with [ExDoc](https://github.com/elixir-lang/ex_doc)
and published on [HexDocs](https://hexdocs.pm). Once published, the docs can
be found at <https://hexdocs.pm/pubsub_grpc>.

## Development with Pub/Sub Emulator

This project includes a Docker Compose configuration for running a local Google Cloud Pub/Sub emulator.

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

#### Connection Pool Configuration

The application uses a connection pool for managing gRPC connections. You can configure the number of worker connections in your config files:

```elixir
config :pubsub_grpc, :connection_pool,
  workers_count: 5
```

The `workers_count` setting determines how many concurrent connections the pool will maintain. If not specified, it defaults to 5 workers.

### Viewing Logs

To view the emulator logs:

```bash
docker-compose logs -f pubsub-emulator
```
