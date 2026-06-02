defmodule PubsubGrpcConnectionTest do
  use ExUnit.Case

  alias PubsubGrpc.Client

  @moduletag :connection_pool

  describe "connection pool" do
    setup do
      # Wait for pool to be ready (connections are established asynchronously)
      wait_for_pool(30)
      :ok
    end

    test "application starts with connection pool" do
      # Check that the connection pool supervisor is registered
      # New architecture uses PubsubGrpc.ConnectionPool.Supervisor as the process name
      assert Process.whereis(PubsubGrpc.ConnectionPool.Supervisor) != nil
    end

    test "can execute simple operation through pool" do
      # The pool is healthy (setup waits for it), so checkout succeeds and the
      # operation's return value is wrapped in the outer {:ok, _} from execute/2.
      simple_operation = fn _channel -> {:ok, "test_result"} end

      assert {:ok, {:ok, "test_result"}} = Client.execute(simple_operation)
    end

    test "connection pool handles multiple concurrent operations" do
      tasks =
        Enum.map(1..10, fn i ->
          Task.async(fn ->
            operation = fn _channel ->
              :timer.sleep(10)
              {:ok, i}
            end

            Client.execute(operation)
          end)
        end)

      results = Enum.map(tasks, &Task.await/1)

      # Every operation should round-trip through the pool successfully and
      # return the integer it was given, across all 10 concurrent tasks.
      ids =
        Enum.map(results, fn result ->
          assert {:ok, {:ok, id}} = result
          id
        end)

      assert Enum.sort(ids) == Enum.to_list(1..10)
    end

    test "connection pool survives and recovers from errors" do
      # execute/2 runs the operation on a checked-out channel without rescuing,
      # so a raise inside the operation propagates to the caller.
      assert_raise RuntimeError, "Simulated error", fn ->
        Client.execute(fn _channel -> raise "Simulated error" end)
      end

      # Pool should still be alive after an operation crashed.
      assert Process.whereis(PubsubGrpc.ConnectionPool.Supervisor) != nil

      # And should still handle new operations.
      assert {:ok, {:ok, "after_error"}} =
               Client.execute(fn _channel -> {:ok, "after_error"} end)
    end

    test "with_connection function works" do
      assert {:ok, {:ok, "with_connection_works"}} =
               Client.with_connection(fn _conn -> {:ok, "with_connection_works"} end)
    end

    test "connection pool handles graceful disconnect without FunctionClauseError" do
      # This test verifies our fix for the GRPC v0.11.5 disconnect issue
      # where FunctionClauseError was thrown during pool shutdown

      # Stop the pool - this should not raise FunctionClauseError
      result =
        try do
          GrpcConnectionPool.stop(PubsubGrpc.ConnectionPool)
          :ok
        rescue
          error -> {:error, error}
        catch
          :exit, reason -> {:exit, reason}
        end

      assert result == :ok,
             "Pool shutdown should complete without errors, got: #{inspect(result)}"

      # Restart the pool for subsequent tests
      # The application supervisor will restart it automatically
      wait_for_pool_restart(10)
    end

    test "worker cleanup handles different channel types safely" do
      # This test specifically targets our worker cleanup fix
      # We can't directly test the cleanup_connection function, but we can
      # test that the pool can handle multiple start/stop cycles without crashes

      for _i <- 1..3 do
        # Stop the pool
        result = GrpcConnectionPool.stop(PubsubGrpc.ConnectionPool)
        assert result == :ok

        # Wait a bit
        :timer.sleep(50)

        # Wait for restart
        wait_for_pool_restart(10)
      end

      # Final verification that the pool is still functional
      assert Process.whereis(PubsubGrpc.ConnectionPool.Supervisor) != nil
    end
  end

  describe "connection configuration" do
    test "reads emulator configuration" do
      config = Application.get_env(:pubsub_grpc, :emulator)

      assert config != nil
      assert config[:project_id] == "test-project-id"
      assert config[:host] == "localhost"
      assert config[:port] == 8085
    end
  end

  # Helper function to wait for pool to be ready
  defp wait_for_pool(retries) when retries <= 0 do
    # If pool never becomes healthy, that's OK for some tests
    # Just ensure the supervisor is registered
    :ok
  end

  defp wait_for_pool(retries) do
    # Check if supervisor is registered (faster than waiting for connections)
    if Process.whereis(PubsubGrpc.ConnectionPool.Supervisor) do
      # Supervisor exists, wait for connections to establish
      case GrpcConnectionPool.status(PubsubGrpc.ConnectionPool) do
        %{status: :healthy} ->
          :ok

        _ ->
          :timer.sleep(100)
          wait_for_pool(retries - 1)
      end
    else
      # Supervisor not yet registered
      :timer.sleep(100)
      wait_for_pool(retries - 1)
    end
  end

  # Helper function to wait for pool restart after shutdown
  defp wait_for_pool_restart(retries) when retries <= 0, do: :ok

  defp wait_for_pool_restart(retries) do
    # Wait for the supervisor to be restarted by the application supervisor
    if Process.whereis(PubsubGrpc.ConnectionPool.Supervisor) do
      :ok
    else
      :timer.sleep(200)
      wait_for_pool_restart(retries - 1)
    end
  end
end
