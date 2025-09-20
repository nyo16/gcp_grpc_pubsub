import Config

config :logger, level: :info

config :pubsub_grpc, :emulator,
  project_id: "test-project-id",
  host: "localhost",
  port: 8085
