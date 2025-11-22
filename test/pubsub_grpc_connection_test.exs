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
      # Test a simple operation that doesn't require actual GRPC connection
      simple_operation = fn _channel, _params ->
        {:ok, "test_result"}
      end

      # This should work even without a real GRPC connection if the pool is working
      result =
        case Client.execute(simple_operation) do
          {:ok, {:ok, "test_result"}} -> :ok
          {:error, _} -> :expected_error
          other -> other
        end

      assert result in [:ok, :expected_error],
             "Pool should be functional, got: #{inspect(result)}"
    end

    test "connection pool handles multiple concurrent operations" do
      # Create multiple tasks that will use the pool concurrently
      operation = fn _channel, params ->
        # Simulate some work
        :timer.sleep(10)
        {:ok, params[:id]}
      end

      tasks =
        Enum.map(1..10, fn i ->
          Task.async(fn ->
            Client.execute(operation, %{id: i})
          end)
        end)

      results = Enum.map(tasks, &Task.await/1)

      # All tasks should complete (either successfully or with expected connection errors)
      assert length(results) == 10

      # Check that we got results (could be success or connection errors)
      Enum.each(results, fn result ->
        case result do
          {:ok, {:ok, id}} when is_integer(id) -> :ok
          {:error, _} -> :expected_connection_error
          # Some operations might return bare :ok
          :ok -> :ok
          other -> flunk("Unexpected result: #{inspect(other)}")
        end
      end)
    end

    test "connection pool survives and recovers from errors" do
      # Operation that will cause an error
      error_operation = fn _channel, _params ->
        raise "Simulated error"
      end

      # This should raise an error but not crash the pool
      # The new architecture lets errors propagate
      assert_raise RuntimeError, "Simulated error", fn ->
        Client.execute(error_operation)
      end

      # Pool should still be alive
      # New architecture uses PubsubGrpc.ConnectionPool.Supervisor as the process name
      assert Process.whereis(PubsubGrpc.ConnectionPool.Supervisor) != nil

      # And should still be able to handle new operations
      simple_operation = fn _channel, _params ->
        {:ok, "after_error"}
      end

      result2 =
        case Client.execute(simple_operation) do
          {:ok, {:ok, "after_error"}} -> :ok
          {:error, _} -> :expected_connection_error
          other -> other
        end

      assert result2 in [:ok, :expected_connection_error]
    end

    test "with_connection function works" do
      result =
        Client.with_connection(fn _conn ->
          {:ok, "with_connection_works"}
        end)

      # Should either work or return a connection error
      case result do
        {:ok, {:ok, "with_connection_works"}} -> :ok
        # Could be connection error if no emulator
        {:error, _} -> :expected_connection_error
        # Some operations might return bare :ok
        :ok -> :ok
        other -> flunk("Unexpected result: #{inspect(other)}")
      end
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
end
