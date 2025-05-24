import Config

config :pubsub_grpc, :emulator,
  project_id: "my-project-id",
  host: "localhost",
  port: 8085

config :pubsub_grpc, :connection_pool,
  workers_count: 5
