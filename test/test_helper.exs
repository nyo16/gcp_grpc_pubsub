# Check if emulator is reachable
emulator_available? =
  case :gen_tcp.connect(~c"localhost", 8085, [:binary, active: false], 1000) do
    {:ok, socket} ->
      :gen_tcp.close(socket)
      true

    {:error, _} ->
      false
  end

# Exclude integration tests when emulator is not running
exclude =
  if emulator_available? do
    []
  else
    IO.puts("Pub/Sub emulator not detected — skipping integration tests")

    IO.puts(
      "Start with: docker run --rm -p 127.0.0.1:8085:8085 google/cloud-sdk:489.0.0-stable bash -c " <>
        "\"gcloud beta emulators pubsub start --project=test-project-id --host-port='0.0.0.0:8085'\""
    )

    [:integration, :connection_pool]
  end

ExUnit.start(exclude: exclude)

{:ok, _} = Application.ensure_all_started(:pubsub_grpc)

# Connections are established asynchronously; don't let the first integration
# test race the pool.
if emulator_available? do
  case GrpcConnectionPool.await_ready(PubsubGrpc.ConnectionPool, 5_000) do
    :ok -> :ok
    {:error, reason} -> raise "PubsubGrpc.ConnectionPool not ready after 5s: #{inspect(reason)}"
  end
end
