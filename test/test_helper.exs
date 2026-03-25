# Load support files
Code.require_file("support/emulator_helper.ex", __DIR__)

# Configure ExUnit
ExUnit.start()

# Start the application
{:ok, _} = Application.ensure_all_started(:pubsub_grpc)

# Skip emulator startup for tests
IO.puts("Emulator startup skipped - running tests without emulator")
IO.puts("To run with emulator, start it manually with:")
IO.puts("docker run --rm -p 8085:8085 google/cloud-sdk:emulators /bin/bash -c \"gcloud beta emulators pubsub start --project=test-project-id --host-port='0.0.0.0:8085'\"")
