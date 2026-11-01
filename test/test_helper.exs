# Check if emulator is reachable
emulator_available? =
  case :gen_tcp.connect(~c"localhost", 8085, [:binary, active: false], 1000) do
    {:ok, socket} ->
      :gen_tcp.close(socket)
      true

    {:error, _} ->
      false
  end

# `mix emulator.start` (dev/mix/tasks/, repo checkout only) runs the same container.
# Image pin: keep in sync with docker-compose.yml (the Dependabot-tracked source of truth).
start_hint =
  "mix emulator.start, or: " <>
    "docker run --rm -p 127.0.0.1:8085:8085 " <>
    "google/cloud-sdk:489.0.0-emulators@sha256:6e0520e94bf93e4f4d53ffd8f52b664bd614b73e2f2e8467f54f6c9a9f4d0763 " <>
    "bash -c " <>
    "\"gcloud beta emulators pubsub start --project=test-project-id --host-port='0.0.0.0:8085'\""

# Exclude integration tests when the emulator is not running, except in CI (which sets
# CI=true), where skipping them would hide a broken emulator.
exclude =
  cond do
    emulator_available? ->
      []

    System.get_env("CI") not in [nil, "", "false"] ->
      raise "Pub/Sub emulator not reachable on localhost:8085, and CI is set: " <>
              "integration tests must run in CI. Start it with: #{start_hint}"

    true ->
      IO.puts("Pub/Sub emulator not detected — skipping integration tests")
      IO.puts("Start with: #{start_hint}")
      [:integration, :connection_pool]
  end

ExUnit.start(exclude: exclude)

{:ok, _} = Application.ensure_all_started(:pubsub_grpc)

# Per-run token in emulator resource names (EmulatorHelper.unique_name/1):
# System.unique_integer/1 restarts with every VM, and resources leaked by an
# aborted run stay in a long-lived local emulator.
Application.put_env(
  :pubsub_grpc,
  :test_run_id,
  Base.encode32(:crypto.strong_rand_bytes(5), case: :lower, padding: false)
)

# Connections are established asynchronously; don't let the first integration
# test race the pool.
if emulator_available? do
  case GrpcConnectionPool.await_ready(PubsubGrpc.ConnectionPool, 5_000) do
    :ok -> :ok
    {:error, reason} -> raise "PubsubGrpc.ConnectionPool not ready after 5s: #{inspect(reason)}"
  end
end
