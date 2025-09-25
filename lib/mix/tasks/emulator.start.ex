defmodule Mix.Tasks.Emulator.Start do
  use Mix.Task

  @shortdoc "Start Google Cloud Pub/Sub emulator"
  @moduledoc """
  Start the Google Cloud Pub/Sub emulator in a Docker container.

  ## Usage

      mix emulator.start

  The emulator runs on port 8085 and uses the project ID 'test-project-id'.
  The container is named 'pubsub-emulator' for easy management.
  """

  def run(_args) do
    Mix.Shell.IO.info("Starting Google Cloud Pub/Sub emulator...")

    # Check if emulator is already running
    case System.cmd("docker", ["ps", "-q", "-f", "name=pubsub-emulator"], stderr_to_stdout: true) do
      {output, 0} ->
        if String.trim(output) != "" do
          Mix.Shell.IO.info("Emulator is already running")
        else
          start_emulator()
        end
      _ ->
        start_emulator()
    end
  end

  defp start_emulator do
    # Start the emulator
    cmd = [
      "run", "--rm", "-d",
      "--name", "pubsub-emulator",
      "-p", "8085:8085",
      "google/cloud-sdk:emulators",
      "/bin/bash", "-c",
      "gcloud beta emulators pubsub start --project=test-project-id --host-port='0.0.0.0:8085'"
    ]

    case System.cmd("docker", cmd, stderr_to_stdout: true) do
      {_output, 0} ->
        Mix.Shell.IO.info("Emulator started successfully on port 8085")
        Mix.Shell.IO.info("Project ID: test-project-id")
        Mix.Shell.IO.info("Use 'mix emulator.stop' to stop the emulator")
      {error, _} ->
        Mix.Shell.IO.error("Failed to start emulator: #{error}")
    end
  end
end