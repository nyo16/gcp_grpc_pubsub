defmodule PubsubGrpc.Auth.CLI do
  @moduledoc false
  # Runs an external command (gcloud) with a deadline.
  #
  # `System.cmd/3` cannot be used: when the calling process is killed (e.g. by
  # `Task.Supervisor.terminate_child/2` after a timeout), the port closes but the
  # OS process keeps running. Here the OS process is killed explicitly when the
  # deadline passes or when the calling process is asked to shut down.

  @spec run(String.t(), [String.t()], non_neg_integer()) ::
          {:ok, binary(), non_neg_integer()} | {:error, :timeout | :port_closed}
  def run(executable, args, timeout) do
    previous_trap = Process.flag(:trap_exit, true)

    try do
      port =
        Port.open({:spawn_executable, executable}, [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          args: args
        ])

      os_pid = os_pid(port)
      deadline = System.monotonic_time(:millisecond) + timeout
      collect(port, os_pid, deadline, [])
    after
      Process.flag(:trap_exit, previous_trap)
    end
  end

  defp collect(port, os_pid, deadline, acc) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} ->
        collect(port, os_pid, deadline, [acc | data])

      {^port, {:exit_status, status}} ->
        flush_port_exit(port)
        {:ok, IO.iodata_to_binary(acc), status}

      # The port died before reporting an exit status.
      {:EXIT, ^port, _reason} ->
        stop(port, os_pid)
        {:error, :port_closed}

      # A linked process finished normally: not a shutdown request.
      {:EXIT, _from, :normal} ->
        collect(port, os_pid, deadline, acc)

      # Shutdown requested (e.g. Task.Supervisor.terminate_child/2).
      {:EXIT, _from, reason} ->
        stop(port, os_pid)
        exit(reason)
    after
      remaining ->
        stop(port, os_pid)
        {:error, :timeout}
    end
  end

  # `nil` when the command already exited and its port closed: its output and exit
  # status are then already in the mailbox, and there is no OS process to kill.
  defp os_pid(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} -> os_pid
      nil -> nil
    end
  end

  defp stop(port, os_pid) do
    kill_os_process(os_pid)

    try do
      Port.close(port)
    rescue
      ArgumentError -> :ok
    end

    flush_port_exit(port)
  end

  defp flush_port_exit(port) do
    receive do
      {:EXIT, ^port, _} -> :ok
    after
      0 -> :ok
    end
  end

  defp kill_os_process(nil), do: :ok

  defp kill_os_process(os_pid) do
    pid = Integer.to_string(os_pid)

    case :os.type() do
      {:win32, _} -> System.cmd("taskkill", ["/F", "/PID", pid], stderr_to_stdout: true)
      _ -> System.cmd("kill", ["-KILL", pid], stderr_to_stdout: true)
    end

    :ok
  rescue
    # kill/taskkill not found on PATH
    ErlangError -> :ok
  end
end
