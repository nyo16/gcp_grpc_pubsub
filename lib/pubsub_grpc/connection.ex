defmodule PubsubGrpc.Connection do
  @moduledoc """
  GRPC Connection pool using NimblePool for resource management
  """
  @behaviour NimblePool

  defmodule Error do
    @moduledoc false
    defexception [:message, :grpc_code]
  end

  # NimblePool callbacks

  @impl NimblePool
  def init_worker(pool_state) do
    # Initialize with nil - connections will be created lazily during checkout
    {:ok, nil, pool_state}
  end

  @impl NimblePool
  def handle_checkout(:checkout, _from, channel, pool_state) do
    case channel do
      nil ->
        # No connection yet, create one
        case create_connection() do
          {:ok, new_channel} ->
            {:ok, new_channel, new_channel, pool_state}
          {:error, reason} ->
            {:remove, reason}
        end
      existing_channel ->
        case is_connection_alive?(existing_channel) do
          true ->
            {:ok, existing_channel, existing_channel, pool_state}
          false ->
            # Connection is dead, create a new one
            cleanup_connection(existing_channel)
            case create_connection() do
              {:ok, new_channel} ->
                {:ok, new_channel, new_channel, pool_state}
              {:error, reason} ->
                {:remove, reason}
            end
        end
    end
  end

  @impl NimblePool
  def handle_checkin(channel, _from, _old_channel, pool_state) do
    case is_connection_alive?(channel) do
      true ->
        {:ok, channel, pool_state}
      false ->
        cleanup_connection(channel)
        # Create a new connection to replace the dead one
        case create_connection() do
          {:ok, new_channel} ->
            {:ok, new_channel, pool_state}
          {:error, _reason} ->
            {:remove, :down}
        end
    end
  end

  @impl NimblePool
  def terminate_worker(_reason, channel, pool_state) do
    cleanup_connection(channel)
    {:ok, pool_state}
  end

  # Public API

  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor,
      restart: :permanent,
      shutdown: 5000
    }
  end

  def start_link(opts) do
    pool_opts = [
      worker: {__MODULE__, opts},
      pool_size: Keyword.get(opts, :pool_size, 5),
      name: Keyword.get(opts, :name, __MODULE__)
    ]
    
    NimblePool.start_link(pool_opts)
  end

  def execute(pool, operation_fn, params \\ []) when is_function(operation_fn, 2) do
    try do
      NimblePool.checkout!(pool, :checkout, fn _from, channel ->
        result = operation_fn.(channel, params)
        {result, channel}
      end)
    rescue
      error -> {:error, error}
    catch
      :exit, reason -> {:error, {:exit, reason}}
      error -> {:error, {:throw, error}}
    end
  end

  def with_connection(pool, fun) when is_function(fun, 1) do
    NimblePool.checkout!(pool, :checkout, fn _from, channel ->
      result = fun.(channel)
      {result, channel}
    end)
  end

  # Private functions

  defp create_connection do
    emulator = Application.get_env(:pubsub_grpc, :emulator)

    case emulator do
      nil ->
        ssl_opts = Application.get_env(:google_grpc_pubsub, :ssl_opts, [])
        credentials = GRPC.Credential.new(ssl: ssl_opts)

        case GRPC.Stub.connect("pubsub.googleapis.com:443",
          cred: credentials,
          adapter_opts: [
            http2_opts: %{
              keepalive: 30_000  # Send keepalive every 30 seconds
            }
          ]
        ) do
          {:ok, channel} ->
            {:ok, channel}
          {:error, reason} ->
            # Log connection failures for debugging
            IO.warn("Failed to connect to Google Cloud Pub/Sub: #{inspect(reason)}")
            {:error, reason}
        end

      [project_id: _project_id, host: host, port: port] = _config
      when is_binary(host) and is_number(port) ->
        # For emulator connections, retry with backoff
        create_emulator_connection(host, port, 3)
    end
  end

  # Create emulator connection with retry logic
  defp create_emulator_connection(host, port, retries_left) when retries_left > 0 do
    case GRPC.Stub.connect(host, port,
      adapter_opts: [
        http2_opts: %{
          keepalive: 30_000  # Send keepalive every 30 seconds
        }
      ]
    ) do
      {:ok, channel} ->
        {:ok, channel}
      {:error, _reason} when retries_left > 1 ->
        # Wait and retry
        :timer.sleep(1000)
        create_emulator_connection(host, port, retries_left - 1)
      {:error, reason} ->
        IO.warn("Failed to connect to emulator at #{host}:#{port} after retries: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp create_emulator_connection(_host, _port, 0) do
    {:error, :max_retries_exceeded}
  end

  defp is_connection_alive?(nil), do: false
  defp is_connection_alive?(%GRPC.Channel{adapter_payload: %{conn_pid: pid}} = channel) when is_pid(pid) do
    if Process.alive?(pid) do
      # Additional check: try a simple operation to ensure connection is actually working
      # This helps detect channels that are technically alive but have timed out
      test_connection_health(channel)
    else
      false
    end
  end

  defp is_connection_alive?(_channel), do: false

  # Test if a connection is actually working by attempting a simple operation
  defp test_connection_health(channel) do
    try do
      # Try to list topics with a very small page size - this is a lightweight operation
      # that will fail quickly if the connection is dead
      request = %Google.Pubsub.V1.ListTopicsRequest{
        project: "projects/health-check",  # Doesn't need to exist
        page_size: 1
      }
      
      # Set a short timeout for the health check
      case Google.Pubsub.V1.Publisher.Stub.list_topics(channel, request, timeout: 2000) do
        {:ok, _} -> true
        {:error, %GRPC.RPCError{status: 5}} -> true  # NOT_FOUND is expected and means connection works
        {:error, %GRPC.RPCError{status: 3}} -> true  # INVALID_ARGUMENT is also fine
        {:error, %GRPC.RPCError{status: 7}} -> true  # PERMISSION_DENIED means connection works
        {:error, %GRPC.RPCError{status: 16}} -> true # UNAUTHENTICATED means connection works
        {:error, %GRPC.RPCError{status: 4}} -> false # DEADLINE_EXCEEDED means connection is dead
        {:error, %GRPC.RPCError{status: 14}} -> false # UNAVAILABLE means connection is dead  
        {:error, _} -> false # Any other error likely means dead connection
      end
    rescue
      _ -> false
    catch
      :exit, _ -> false
    end
  end

  defp cleanup_connection(%GRPC.Channel{} = channel) do
    try do
      GRPC.Stub.disconnect(channel)
    rescue
      _ -> :ok
    catch
      _ -> :ok
    end
  end

  defp cleanup_connection(_), do: :ok
end
