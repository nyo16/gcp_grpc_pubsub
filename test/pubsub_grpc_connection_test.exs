defmodule PubsubGrpcConnectionTest do
  # Each test gets its own pool, so the application's pool is never stopped.
  use ExUnit.Case, async: true

  alias PubsubGrpc.{Client, Error}

  @moduletag :integration
  @moduletag :connection_pool

  setup do
    pool = :"pubsub_grpc_test_pool_#{System.unique_integer([:positive])}"

    {:ok, config} =
      GrpcConnectionPool.Config.local(
        host: "localhost",
        port: 8085,
        pool_name: pool,
        pool_size: 2
      )

    start_supervised!({GrpcConnectionPool, config})
    assert :ok = GrpcConnectionPool.await_ready(pool, 5_000)

    %{pool: pool}
  end

  test "the application pool serves requests on the default path" do
    assert %{status: :healthy} = Client.status()
    assert {:ok, %{topics: topics}} = PubsubGrpc.list_topics("test-project-id")
    assert is_list(topics)
  end

  test "execute/2 runs the callback with a channel and returns its result", %{pool: pool} do
    assert {:ok, {:ok, "test_result"}} =
             Client.execute(fn %GRPC.Channel{} -> {:ok, "test_result"} end, pool: pool)
  end

  test "with_connection/2 is an alias for execute/2", %{pool: pool} do
    assert {:ok, {:ok, "with_connection_works"}} =
             Client.with_connection(fn _ -> {:ok, "with_connection_works"} end, pool: pool)
  end

  test "handles concurrent callers", %{pool: pool} do
    results =
      1..10
      |> Enum.map(fn i ->
        Task.async(fn -> Client.execute(fn _ -> {:ok, i} end, pool: pool) end)
      end)
      |> Task.await_many()

    assert results == Enum.map(1..10, &{:ok, {:ok, &1}})
  end

  test "a raising callback propagates and the pool keeps serving", %{pool: pool} do
    assert_raise RuntimeError, "Simulated error", fn ->
      Client.execute(fn _ -> raise "Simulated error" end, pool: pool)
    end

    assert {:ok, {:ok, "after_error"}} =
             Client.execute(fn _ -> {:ok, "after_error"} end, pool: pool)
  end

  test "status/1 reports a healthy dedicated pool", %{pool: pool} do
    assert %{pool_name: ^pool, status: :healthy, current_size: 2, expected_size: 2} =
             Client.status(pool: pool)
  end

  test "public API calls can target a dedicated pool", %{pool: pool} do
    assert {:ok, %{topics: topics}} = PubsubGrpc.list_topics("test-project-id", pool: pool)
    assert is_list(topics)
  end

  test "a stopped pool yields connection errors", %{pool: pool} do
    # The pool's child id is its name.
    stop_supervised!(pool)

    assert {:error, :not_connected} = Client.execute(fn _ -> :unreachable end, pool: pool)

    assert {:error, %Error{code: :connection_error, details: :not_connected}} =
             PubsubGrpc.list_topics("test-project-id", pool: pool, timeout: 100)
  end
end
