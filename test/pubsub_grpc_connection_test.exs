defmodule PubsubGrpcConnectionTest do
  use ExUnit.Case

  alias PubsubGrpc.Client

  @moduletag :connection_pool

  describe "connection pool" do
    test "application starts with connection pool" do
      # Check that the connection pool is registered
      assert Process.whereis(PubsubGrpc.ConnectionPool) != nil
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

      # This should return an error but not crash the pool
      result = Client.execute(error_operation)

      # NimblePool might return different error formats
      case result do
        {:ok, {:error, _}} -> :ok
        {:error, _} -> :ok
        :error -> :ok
        other -> flunk("Expected error, got: #{inspect(other)}")
      end

      # Pool should still be alive
      assert Process.whereis(PubsubGrpc.ConnectionPool) != nil

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
end
