defmodule PubsubGrpc.Eventually do
  @moduledoc """
  Deadline-bounded polling for tests that wait on asynchronous effects.
  """

  import ExUnit.Assertions, only: [flunk: 1]

  @doc """
  Calls `fun` every `interval` ms until it returns a truthy value, which is
  returned. Flunks the test if `timeout` ms pass first.
  """
  @spec eventually((-> term()), non_neg_integer(), pos_integer()) :: term()
  def eventually(fun, timeout \\ 2_000, interval \\ 50) when is_function(fun, 0) do
    do_eventually(fun, System.monotonic_time(:millisecond) + timeout, interval)
  end

  defp do_eventually(fun, deadline, interval) do
    cond do
      value = fun.() ->
        value

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("condition not met before timeout")

      true ->
        Process.sleep(interval)
        do_eventually(fun, deadline, interval)
    end
  end

  @doc """
  Pulls from `subscription_id` until at least `count` messages have arrived
  and returns them all. Any pull error fails the test.
  """
  @spec pull_until(String.t(), String.t(), pos_integer(), non_neg_integer()) :: [struct()]
  def pull_until(project_id, subscription_id, count, timeout \\ 5_000) do
    do_pull_until(project_id, subscription_id, count, [], deadline(timeout))
  end

  defp do_pull_until(project_id, subscription_id, count, acc, deadline) do
    acc =
      case PubsubGrpc.pull(project_id, subscription_id, 10) do
        {:ok, messages} -> acc ++ messages
        {:error, error} -> flunk("pull failed: #{inspect(error)}")
      end

    cond do
      length(acc) >= count ->
        acc

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("expected #{count} messages before timeout, got #{length(acc)}")

      true ->
        Process.sleep(50)
        do_pull_until(project_id, subscription_id, count, acc, deadline)
    end
  end

  defp deadline(timeout), do: System.monotonic_time(:millisecond) + timeout
end
