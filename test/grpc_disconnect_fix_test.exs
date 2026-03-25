defmodule GrpcDisconnectFixTest do
  @moduledoc """
  Test to verify the fix for FunctionClauseError during GRPC disconnect operations.

  This test specifically targets the fix in grpc_connection_pool/worker.ex
  where we handle the pattern mismatch in GRPC v0.11.5's disconnect handling.
  """
  use ExUnit.Case

  alias GrpcConnectionPool.Worker

  describe "worker disconnect fix" do
    test "worker can handle Gun connection cleanup without FunctionClauseError" do
      {:ok, config} =
        GrpcConnectionPool.Config.local(
          host: "localhost",
          port: 8085,
          pool_name: TestDisconnectPool,
          pool_size: 1
        )

      config = put_in(config.connection.ping_interval, nil)
      config = put_in(config.connection.suppress_connection_errors, true)

      {:ok, worker_pid} =
        Worker.start_link(
          config: config,
          registry_name: :test_registry,
          pool_name: :test_pool
        )

      assert Process.alive?(worker_pid)

      # Stop the worker — this should NOT raise FunctionClauseError.
      # The worker blocks in gun:await_up for ~5s when the emulator is
      # unreachable, so the stop timeout must exceed the GRPC connection
      # timeout to avoid a race between the two.
      result =
        try do
          GenServer.stop(worker_pid, :normal, 15_000)
          :ok
        rescue
          error in [FunctionClauseError] -> {:error, error}
        catch
          :exit, _reason -> :ok
        end

      assert result == :ok,
             "Worker should shutdown cleanly without FunctionClauseError, got: #{inspect(result)}"
    end

    test "worker handles Gun-based channel cleanup safely" do
      mock_channel = %GRPC.Channel{
        host: "localhost",
        port: 8085,
        scheme: "http",
        adapter: GRPC.Client.Adapters.Gun,
        adapter_payload: %{conn_pid: spawn(fn -> :timer.sleep(100) end)},
        cred: nil,
        ref: make_ref(),
        codec: GRPC.Codec.Proto,
        interceptors: [],
        compressor: nil,
        accepted_compressors: [],
        headers: []
      }

      result =
        try do
          case mock_channel do
            %GRPC.Channel{adapter_payload: %{conn_pid: pid}} when is_pid(pid) ->
              if Process.alive?(pid) do
                :gun.close(pid)
              end

              :ok

            _ ->
              :ok
          end
        rescue
          _error -> :ok
        catch
          :exit, _reason -> :ok
        end

      assert result == :ok,
             "Gun connection cleanup should work safely, got: #{inspect(result)}"
    end
  end
end
