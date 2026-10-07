defmodule PubsubGrpc.Auth.Cache do
  @moduledoc false
  # Owns the :pubsub_grpc_auth_cache ETS table and coordinates token refreshes.
  #
  # - The table is `:protected`: any process may read it (lock-free cache hits in
  #   `PubsubGrpc.Auth.get_token/0`), but only this process writes it.
  # - Refreshes are single-flight: on a cache miss, callers `refresh/2`. The first
  #   caller starts one fetch in a `PubsubGrpc.TaskSupervisor` task; callers that
  #   arrive while it is in flight are queued and all receive the same result.
  # - This process never runs the fetch itself, so it is never blocked by I/O.
  # - A fetch that exceeds its timeout is terminated and every waiter gets a
  #   `:deadline_exceeded` error.

  use GenServer

  alias PubsubGrpc.Error

  @table :pubsub_grpc_auth_cache
  @key :token
  @task_supervisor PubsubGrpc.TaskSupervisor

  @typedoc "What a token fetcher returns: a token with its TTL, or an error."
  @type fetch_result :: {:ok, String.t(), non_neg_integer()} | {:error, Error.t()}

  @spec start_link(any()) :: GenServer.on_start()
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @spec table() :: atom()
  def table, do: @table

  @doc """
  Reads the cached token without going through the Cache process.
  """
  @spec lookup() :: {:ok, String.t()} | :miss
  def lookup do
    case :ets.lookup(@table, @key) do
      [{@key, token, expires_at}] ->
        if System.monotonic_time(:millisecond) < expires_at, do: {:ok, token}, else: :miss

      [] ->
        :miss
    end
  rescue
    # Table doesn't exist (Cache not started yet, or restarting).
    ArgumentError -> :miss
  end

  @doc """
  Returns the cached token, or fetches one with `fetcher` (at most one fetch in
  flight at a time). Never exits: an unavailable Cache process is an error.
  """
  @spec refresh((-> fetch_result()), pos_integer()) ::
          {:ok, String.t()} | {:error, Error.t()}
  def refresh(fetcher, timeout)
      when is_function(fetcher, 0) and is_integer(timeout) and timeout > 0 do
    GenServer.call(__MODULE__, {:refresh, fetcher, timeout}, timeout + 1_000)
  catch
    :exit, {:timeout, _} ->
      {:error, Error.new(:deadline_exceeded, "auth token fetch timed out")}

    :exit, reason ->
      {:error, Error.new(:unauthenticated, "auth token cache unavailable", exit_tag(reason))}
  end

  @doc """
  Deletes the cached token. A fetch already in flight still answers its waiters,
  but its token is not stored. A no-op if the Cache process is not running (its
  table, and therefore the cached token, does not exist then either).
  """
  @spec clear() :: :ok
  def clear do
    GenServer.call(__MODULE__, :clear)
  catch
    :exit, _ -> :ok
  end

  @doc """
  Deletes the cached token only if it is `token`.
  """
  @spec invalidate(String.t()) :: :ok
  def invalidate(token) when is_binary(token) do
    GenServer.call(__MODULE__, {:invalidate, token})
  catch
    :exit, _ -> :ok
  end

  # Server

  @impl true
  def init(:ok) do
    :ets.new(@table, [:named_table, :protected, :set, read_concurrency: true])
    # `inflight` is the current fetch; new callers join it. A fetch that was in
    # flight when `clear/0` ran moves to `stale`: it still answers its own waiters,
    # but its token is not stored and nobody new joins it.
    {:ok, %{inflight: nil, stale: %{}}}
  end

  @impl true
  def handle_call({:refresh, fetcher, timeout}, from, state) do
    case {lookup(), state.inflight} do
      {{:ok, token}, _} ->
        {:reply, {:ok, token}, state}

      {:miss, nil} ->
        task = Task.Supervisor.async_nolink(@task_supervisor, fn -> safe_fetch(fetcher) end)
        timer = Process.send_after(self(), {:refresh_timeout, task.ref}, timeout)
        {:noreply, %{state | inflight: %{task: task, timer: timer, waiters: [from]}}}

      {:miss, inflight} ->
        {:noreply, %{state | inflight: %{inflight | waiters: [from | inflight.waiters]}}}
    end
  end

  def handle_call(:clear, _from, state) do
    :ets.delete_all_objects(@table)

    state =
      case state.inflight do
        nil ->
          state

        %{task: %Task{ref: ref}} = inflight ->
          %{state | inflight: nil, stale: Map.put(state.stale, ref, inflight)}
      end

    {:reply, :ok, state}
  end

  def handle_call({:invalidate, token}, _from, state) do
    :ets.match_delete(@table, {@key, token, :_})
    {:reply, :ok, state}
  end

  @impl true
  def handle_info({ref, result}, state) when is_reference(ref) do
    case take_fetch(state, ref) do
      {:ok, fetch, current?, state} ->
        Process.demonitor(ref, [:flush])
        Process.cancel_timer(fetch.timer)
        result = normalize(result)

        # A stale fetch was cleared while in flight: answer its waiters, but don't
        # cache a token that may come from the credentials the clear was meant to drop.
        if current?, do: store(result)

        reply_all(fetch.waiters, result)
        {:noreply, state}

      :error ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case take_fetch(state, ref) do
      {:ok, fetch, _current?, state} ->
        Process.cancel_timer(fetch.timer)

        reply_all(
          fetch.waiters,
          {:error, Error.new(:unauthenticated, "auth token fetch crashed")}
        )

        {:noreply, state}

      :error ->
        {:noreply, state}
    end
  end

  def handle_info({:refresh_timeout, ref}, state) do
    case take_fetch(state, ref) do
      {:ok, fetch, _current?, state} ->
        Process.demonitor(ref, [:flush])

        reply_all(
          fetch.waiters,
          {:error, Error.new(:deadline_exceeded, "auth token fetch timed out")}
        )

        # Reply first: terminating may take as long as the task's own cleanup.
        Task.Supervisor.terminate_child(@task_supervisor, fetch.task.pid)
        {:noreply, state}

      :error ->
        {:noreply, state}
    end
  end

  # Late results/timeouts of a fetch that was already resolved.
  def handle_info(_msg, state), do: {:noreply, state}

  defp take_fetch(%{inflight: %{task: %Task{ref: ref}} = fetch} = state, ref),
    do: {:ok, fetch, true, %{state | inflight: nil}}

  defp take_fetch(state, ref) do
    case Map.pop(state.stale, ref) do
      {nil, _} -> :error
      {fetch, stale} -> {:ok, fetch, false, %{state | stale: stale}}
    end
  end

  defp safe_fetch(fetcher) do
    fetcher.()
  rescue
    e -> {:error, Error.new(:unauthenticated, "auth token fetch crashed", e.__struct__)}
  catch
    kind, _reason -> {:error, Error.new(:unauthenticated, "auth token fetch crashed", kind)}
  end

  defp normalize({:ok, token, ttl_ms} = result)
       when is_binary(token) and is_integer(ttl_ms) and ttl_ms >= 0,
       do: result

  defp normalize({:error, %Error{}} = error), do: error

  # Never echo the unexpected value: it may contain a token.
  defp normalize(_other),
    do: {:error, Error.new(:unauthenticated, "token fetcher returned an unexpected value")}

  defp store({:ok, token, ttl_ms}) do
    expires_at = System.monotonic_time(:millisecond) + ttl_ms
    :ets.insert(@table, {@key, token, expires_at})
  end

  defp store(_error), do: :ok

  defp reply_all(waiters, {:ok, token, _ttl_ms}), do: reply_all(waiters, {:ok, token})
  defp reply_all(waiters, reply), do: Enum.each(waiters, &GenServer.reply(&1, reply))

  defp exit_tag({reason, {GenServer, :call, _}}), do: reason
  defp exit_tag(reason), do: reason
end
