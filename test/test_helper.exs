# Load support files
Code.require_file("support/emulator_helper.ex", __DIR__)

# Configure ExUnit
ExUnit.start()

# Start the application
{:ok, _} = Application.ensure_all_started(:pubsub_grpc)

# Start emulator for integration tests
case PubsubGrpc.EmulatorHelper.start_emulator() do
  :ok ->
    IO.puts("Pub/Sub emulator started successfully")

    # Register cleanup on exit
    ExUnit.after_suite(fn _results ->
      PubsubGrpc.EmulatorHelper.stop_emulator()
    end)

  {:error, reason} ->
    IO.puts("Warning: Could not start emulator: #{inspect(reason)}")
    IO.puts("Integration tests will be skipped")
end
