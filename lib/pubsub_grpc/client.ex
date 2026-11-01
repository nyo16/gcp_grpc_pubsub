defmodule PubsubGrpc.Client do
  @moduledoc false

  # Internal: checks out a channel from the pool and runs a callback on it, returning
  # `{:ok, callback_result}` without normalizing errors or attaching auth. The public
  # entry point is `PubsubGrpc.execute/2`, which normalizes errors to
  # `PubsubGrpc.Error`; callbacks get auth options from `PubsubGrpc.Auth.request_opts/1`.

  alias PubsubGrpc.{Config, Error}

  @doc """
  Execute a gRPC operation using a connection from the pool.

  ## Parameters
  - `operation_fn`: A 1-arity function that receives a gRPC channel and returns a result
  - `opts`: Optional parameters
    - `:pool` - Pool name to use (default: the configured pool, `PubsubGrpc.ConnectionPool`
      unless `config :pubsub_grpc, GrpcConnectionPool` sets `pool: [name: ...]`)
    - `:timeout` - Bounds the wait for a connection (see below; default: the
      `:default_timeout` app env, 30s)

  If no connection is ready (`:not_connected`, e.g. right after startup or while
  reconnecting), waits up to `min(timeout, 2_000)` ms for one and retries the
  checkout once.

  ## Returns
  - `{:ok, result}` - Result from the operation function
  - `{:ok, {:error, %PubsubGrpc.Error{code: :unavailable}}}` - The connection process
    exited during the call (busy past the 5 s `GenServer.call` timeout of the grpc
    gun adapter, or dead). The exit reason embeds the request headers and body, so
    it is replaced by an atom tag in `details`.
  - `{:error, reason}` - Error during connection checkout

  Internal: use `PubsubGrpc.execute/2`, which normalizes errors to `PubsubGrpc.Error`.
  """
  @spec execute((PubsubGrpc.channel() -> term()), keyword()) :: {:ok, term()} | {:error, term()}
  def execute(operation_fn, opts \\ []) when is_function(operation_fn, 1) do
    pool_name = opts[:pool] || Config.pool_name()

    case checkout(pool_name, opts) do
      {:ok, channel} -> {:ok, run(operation_fn, channel)}
      {:error, reason} -> {:error, reason}
    end
  end

  # The exit reason of a GenServer.call embeds the call message: for grpc's gun
  # ConnectionProcess that is the request headers (bearer token) and body. Only
  # exits of calls to that process become `:unavailable` (keeping an atom tag);
  # any other exit, e.g. from a GenServer an `execute/2` callback calls, is
  # re-raised unchanged.
  defp run(operation_fn, channel) do
    operation_fn.(channel)
  catch
    :exit, {reason, {GenServer, :call, [_pid, message | _]}} = exit_reason ->
      if connection_process_call?(message) do
        {:error, Error.new(:unavailable, "gRPC connection unavailable", exit_tag(reason))}
      else
        :erlang.raise(:exit, exit_reason, __STACKTRACE__)
      end
  end

  # The messages `GRPC.Client.Adapters.Gun.ConnectionProcess` is called with
  # (`request/4`, `open_stream/3`, `send_data/4`, `cancel/2`).
  defp connection_process_call?({:request, path, headers, _body})
       when is_binary(path) and is_list(headers),
       do: true

  defp connection_process_call?({:open_stream, path, headers})
       when is_binary(path) and is_list(headers),
       do: true

  defp connection_process_call?({:send_data, _stream_ref, fin, _data}) when fin in [:fin, :nofin],
    do: true

  defp connection_process_call?({:cancel, stream_ref}) when is_reference(stream_ref), do: true
  defp connection_process_call?(_message), do: false

  defp exit_tag(reason) when is_atom(reason), do: reason
  defp exit_tag({:shutdown, _}), do: :shutdown
  defp exit_tag(_), do: :unknown

  @max_ready_wait 2_000

  defp checkout(pool_name, opts) do
    with {:error, :not_connected} <- GrpcConnectionPool.get_channel(pool_name),
         :ok <- await_ready(pool_name, opts) do
      GrpcConnectionPool.get_channel(pool_name)
    end
  end

  defp await_ready(pool_name, opts) do
    timeout = opts[:timeout] || Config.default_timeout()

    case GrpcConnectionPool.await_ready(pool_name, max(min(timeout, @max_ready_wait), 1)) do
      :ok -> :ok
      {:error, :timeout} -> {:error, :not_connected}
    end
  rescue
    # await_ready/2 raises if the pool does not exist (no ETS table): nothing to wait for.
    ArgumentError -> {:error, :not_connected}
  end
end
