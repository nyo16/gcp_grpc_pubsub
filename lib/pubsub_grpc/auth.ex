defmodule PubsubGrpc.Auth do
  @moduledoc """
  Authentication module for Google Cloud Pub/Sub.

  Handles token retrieval with ETS-based caching using multiple methods:
  1. Goth library (if available and configured)
  2. gcloud CLI fallback
  3. Returns structured error if no auth available

  ## Configuration

  To use Goth for authentication, add it to your supervision tree:

      children = [
        {Goth, name: MyApp.Goth, source: {:service_account, credentials}},
        # ... other children
      ]

  Then configure PubsubGrpc to use your Goth instance:

      config :pubsub_grpc, :goth, MyApp.Goth

  """

  require Logger

  alias PubsubGrpc.Error

  @cache_table :pubsub_grpc_auth_cache
  @cache_key :token
  # Cache gcloud CLI tokens for 50 minutes (tokens expire in 60 min)
  @cli_token_ttl_ms 50 * 60 * 1000

  @doc false
  @spec init_cache() :: :ok
  def init_cache do
    if :ets.whereis(@cache_table) == :undefined do
      :ets.new(@cache_table, [:named_table, :public, :set])
    end

    :ok
  end

  @doc """
  Clears the cached authentication token.

  Useful when you need to force a token refresh, for example after
  rotating credentials.
  """
  @spec clear_cache() :: :ok
  def clear_cache do
    if :ets.whereis(@cache_table) != :undefined do
      :ets.delete_all_objects(@cache_table)
    end

    :ok
  end

  @doc """
  Gets an authentication token for Google Cloud API calls.

  Returns a token string in the format "Bearer <token>". Tokens are cached
  in ETS and refreshed automatically when expired.

  ## Returns
  - `{:ok, "Bearer <token>"}` - Token retrieved successfully
  - `{:error, %PubsubGrpc.Error{}}` - Unable to get token

  """
  @spec get_token() :: {:ok, String.t()} | {:error, Error.t()}
  def get_token do
    case get_cached_token() do
      {:ok, token} ->
        {:ok, token}

      :miss ->
        fetch_and_cache_token()
    end
  end

  @doc """
  Gets request options including authentication metadata.

  In emulator mode, returns `{:ok, []}` (no auth needed).
  In production, returns `{:ok, [metadata: %{"authorization" => token}]}`.

  ## Returns
  - `{:ok, keyword()}` - Options to pass to gRPC stub functions
  - `{:error, %PubsubGrpc.Error{}}` - Authentication failed

  """
  @spec request_opts() :: {:ok, keyword()} | {:error, Error.t()}
  def request_opts do
    case Application.get_env(:pubsub_grpc, :emulator) do
      nil ->
        case get_token() do
          {:ok, token} ->
            {:ok, [metadata: %{"authorization" => token}]}

          {:error, _} = error ->
            error
        end

      _emulator_config ->
        {:ok, []}
    end
  end

  # Private functions

  defp get_cached_token do
    case :ets.lookup(@cache_table, @cache_key) do
      [{@cache_key, token, expires_at}] ->
        if System.monotonic_time(:millisecond) < expires_at, do: {:ok, token}, else: :miss

      [] ->
        :miss
    end
  rescue
    # Table doesn't exist (Cache GenServer not started yet, or torn down).
    ArgumentError -> :miss
  end

  defp cache_token(token, ttl_ms) do
    expires_at = System.monotonic_time(:millisecond) + ttl_ms
    :ets.insert(@cache_table, {@cache_key, token, expires_at})
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp fetch_and_cache_token do
    {source, fun} =
      case Application.get_env(:pubsub_grpc, :goth) do
        nil -> {:gcloud, fn -> get_token_fallback() end}
        goth_name -> {:goth, fn -> get_token_from_goth(goth_name) end}
      end

    :telemetry.span([:pubsub_grpc, :auth], %{source: source}, fn ->
      result = fun.()
      {result, %{source: source, result: classify(result)}}
    end)
  end

  defp classify({:ok, _}), do: :ok
  defp classify({:error, _}), do: :error

  defp get_token_from_goth(goth_name) do
    if Code.ensure_loaded?(Goth) do
      goth_name |> Goth.fetch() |> handle_goth_result()
    else
      Logger.error("PubsubGrpc: :goth configured but Goth module not loaded")

      {:error,
       Error.new(
         :unauthenticated,
         "Goth configured but not loaded; add :goth to your deps or remove :pubsub_grpc :goth config"
       )}
    end
  rescue
    e ->
      Logger.error("PubsubGrpc: Goth.fetch raised: #{inspect(e.__struct__)}")
      {:error, Error.new(:unauthenticated, "Goth authentication crashed", e)}
  catch
    kind, reason ->
      Logger.error("PubsubGrpc: Goth.fetch exited: #{kind}")
      {:error, Error.new(:unauthenticated, "Goth authentication crashed", {kind, reason})}
  end

  defp handle_goth_result({:ok, %{token: token, type: type} = result})
       when is_binary(token) and is_binary(type) do
    bearer = "#{type} #{token}"
    cache_token(bearer, goth_ttl_ms(result))
    {:ok, bearer}
  end

  defp handle_goth_result({:error, reason}) do
    # Goth was explicitly configured — do not silently fall back to gcloud CLI;
    # surface the original error so the caller knows their chosen auth path failed.
    Logger.warning("PubsubGrpc: Goth.fetch failed (#{error_tag(reason)})")

    {:error, Error.new(:unauthenticated, "Goth authentication failed", reason)}
  end

  defp goth_ttl_ms(%{expires: expires}) when not is_nil(expires) do
    expires_dt =
      cond do
        is_integer(expires) -> DateTime.from_unix!(expires)
        match?(%DateTime{}, expires) -> expires
        true -> nil
      end

    case expires_dt do
      nil -> @cli_token_ttl_ms
      dt -> max(DateTime.diff(dt, DateTime.utc_now(), :millisecond) - 60_000, 0)
    end
  end

  defp goth_ttl_ms(_), do: @cli_token_ttl_ms

  defp get_token_fallback do
    case System.cmd("gcloud", ["auth", "application-default", "print-access-token"],
           stderr_to_stdout: true
         ) do
      {token_output, 0} ->
        token = "Bearer #{String.trim(token_output)}"
        cache_token(token, @cli_token_ttl_ms)
        {:ok, token}

      {error_output, exit_code} ->
        # Log raw stderr at debug only (may contain ADC paths, account emails).
        Logger.debug(fn -> "PubsubGrpc: gcloud stderr: #{String.trim(error_output)}" end)
        Logger.error("PubsubGrpc: gcloud CLI auth failed (exit #{exit_code})")

        {:error,
         Error.new(
           :unauthenticated,
           "gcloud CLI auth failed (exit #{exit_code})",
           {:gcloud_exit, exit_code}
         )}
    end
  rescue
    e ->
      Logger.error("PubsubGrpc: auth unavailable: #{inspect(e.__struct__)}")

      {:error, Error.new(:unauthenticated, "no authentication available", e)}
  catch
    kind, reason ->
      Logger.error("PubsubGrpc: auth unavailable: #{kind}")
      {:error, Error.new(:unauthenticated, "no authentication available", {kind, reason})}
  end

  # Best-effort tag for logging: an atom describing the error shape, never its contents.
  defp error_tag(%{__struct__: mod}), do: mod
  defp error_tag(reason) when is_atom(reason), do: reason
  defp error_tag({tag, _}) when is_atom(tag), do: tag
  defp error_tag(_), do: :unknown
end
