defmodule GrpcDisconnectFixTest do
  @moduledoc """
  Regression test: stopping a connected pool worker must not crash with a
  FunctionClauseError in grpc's Gun disconnect handling.
  """
  use ExUnit.Case, async: true

  import PubsubGrpc.Eventually

  alias GrpcConnectionPool.Worker

  @moduletag :integration

  test "a connected worker stops cleanly" do
    unique = System.unique_integer([:positive])
    registry = :"grpc_disconnect_registry_#{unique}"
    start_supervised!({Registry, keys: :duplicate, name: registry})

    {:ok, config} =
      GrpcConnectionPool.Config.local(
        host: "localhost",
        port: 8085,
        pool_name: :"grpc_disconnect_pool_#{unique}",
        pool_size: 1
      )

    config = put_in(config.connection.ping_interval, nil)

    {:ok, worker_pid} =
      Worker.start_link(config: config, registry_name: registry, pool_name: config.pool.name)

    eventually(fn -> Worker.status(worker_pid) == :connected end, 5_000)

    ref = Process.monitor(worker_pid)
    assert :ok = GenServer.stop(worker_pid, :normal, 15_000)
    assert_receive {:DOWN, ^ref, :process, ^worker_pid, :normal}
  end
end
