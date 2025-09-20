defmodule Mix.Tasks.Emulator.Stop do
  use Mix.Task

  @shortdoc "Stop Google Cloud Pub/Sub emulator"
  @moduledoc """
  Stop the Google Cloud Pub/Sub emulator Docker container.

  ## Usage

      mix emulator.stop

  This stops the 'pubsub-emulator' Docker container if it's running.
  Safe to run even if the emulator is not currently running.
  """

  def run(_args) do
    Mix.Shell.IO.info("Stopping Google Cloud Pub/Sub emulator...")

    case System.cmd("docker", ["stop", "pubsub-emulator"], stderr_to_stdout: true) do
      {_output, 0} ->
        Mix.Shell.IO.info("Emulator stopped successfully")
      {error, _} ->
        if String.contains?(error, "No such container") do
          Mix.Shell.IO.info("Emulator is not running")
        else
          Mix.Shell.IO.error("Failed to stop emulator: #{error}")
        end
    end
  end
end