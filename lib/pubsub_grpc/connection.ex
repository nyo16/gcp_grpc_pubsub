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
      NimblePool.checkout!(pool, :checkout, fn _pool, channel ->
        operation_fn.(channel, params)
      end)
    rescue
      error -> {:error, error}
    catch
      :exit, reason -> {:error, {:exit, reason}}
      error -> {:error, {:throw, error}}
    end
  end

  def with_connection(pool, fun) when is_function(fun, 1) do
    NimblePool.checkout!(pool, :checkout, fn _pool, channel ->
      fun.(channel)
    end)
  end

  # Private functions

  defp create_connection do
    emulator = Application.get_env(:pubsub_grpc, :emulator)

    case emulator do
      nil ->
        ssl_opts = Application.get_env(:google_grpc_pubsub, :ssl_opts, [])
        credentials = GRPC.Credential.new(ssl: ssl_opts)

        GRPC.Stub.connect("pubsub.googleapis.com:443",
          cred: credentials,
          adapter_opts: [
            http2_opts: %{keepalive: :infinity}
          ]
        )

      [project_id: _project_id, host: host, port: port] = _config
      when is_binary(host) and is_number(port) ->
        GRPC.Stub.connect(host, port,
          adapter_opts: [
            http2_opts: %{keepalive: :infinity}
          ]
        )
    end
  end

  defp is_connection_alive?(nil), do: false
  defp is_connection_alive?(%GRPC.Channel{adapter_payload: %{conn_pid: pid}}) when is_pid(pid) do
    Process.alive?(pid)
  end

  defp is_connection_alive?(_channel), do: false

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
