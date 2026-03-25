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
    if :ets.whereis(@cache_table) != :undefined do
      case :ets.lookup(@cache_table, @cache_key) do
        [{@cache_key, token, expires_at}] ->
          if System.monotonic_time(:millisecond) < expires_at do
            {:ok, token}
          else
            :miss
          end

        [] ->
          :miss
      end
    else
      :miss
    end
  end

  defp cache_token(token, ttl_ms) do
    if :ets.whereis(@cache_table) != :undefined do
      expires_at = System.monotonic_time(:millisecond) + ttl_ms
      :ets.insert(@cache_table, {@cache_key, token, expires_at})
    end

    :ok
  end

  defp fetch_and_cache_token do
    case Application.get_env(:pubsub_grpc, :goth) do
      nil ->
        get_token_fallback()

      goth_name ->
        get_token_from_goth(goth_name)
    end
  end

  defp get_token_from_goth(goth_name) do
    if Code.ensure_loaded?(Goth) do
      case Goth.fetch(goth_name) do
        {:ok, %{token: token, type: type, expires: expires}} ->
          bearer = "#{type} #{token}"
          ttl_ms = max(DateTime.diff(expires, DateTime.utc_now(), :millisecond) - 60_000, 0)
          cache_token(bearer, ttl_ms)
          {:ok, bearer}

        {:ok, %{token: token, type: type}} ->
          bearer = "#{type} #{token}"
          cache_token(bearer, @cli_token_ttl_ms)
          {:ok, bearer}

        {:error, reason} ->
          Logger.warning(
            "PubsubGrpc: Goth.fetch failed (#{inspect(reason)}), falling back to gcloud CLI"
          )

          case get_token_fallback() do
            {:ok, _} = ok ->
              ok

            {:error, _} ->
              {:error,
               Error.new(
                 :unauthenticated,
                 "authentication failed: Goth error: #{inspect(reason)}",
                 reason
               )}
          end
      end
    else
      get_token_fallback()
    end
  end

  defp get_token_fallback do
    try do
      case System.cmd("gcloud", ["auth", "application-default", "print-access-token"],
             stderr_to_stdout: true
           ) do
        {token_output, 0} ->
          token = "Bearer #{String.trim(token_output)}"
          cache_token(token, @cli_token_ttl_ms)
          {:ok, token}

        {error_output, exit_code} ->
          Logger.error(
            "PubsubGrpc: gcloud CLI auth failed (exit #{exit_code}): #{String.trim(error_output)}"
          )

          {:error,
           Error.new(:unauthenticated, "gcloud CLI auth failed: #{String.trim(error_output)}")}
      end
    rescue
      e ->
        Logger.error("PubsubGrpc: auth unavailable - #{Exception.message(e)}")

        {:error,
         Error.new(:unauthenticated, "no authentication available: #{Exception.message(e)}", e)}
    catch
      kind, reason ->
        Logger.error("PubsubGrpc: auth unavailable - #{inspect({kind, reason})}")
        {:error, Error.new(:unauthenticated, "no authentication available", {kind, reason})}
    end
  end
end
