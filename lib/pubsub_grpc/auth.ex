defmodule PubsubGrpc.Auth do
  @moduledoc """
  Authentication module for Google Cloud Pub/Sub.

  Handles token retrieval with ETS-based caching using multiple methods:
  1. Goth library (if available and configured)
  2. gcloud CLI fallback
  3. Returns structured error if no auth available

  Cached tokens are read without any process hop. On a cache miss, exactly one
  token fetch runs at a time: concurrent callers wait for that fetch and share
  its result instead of each starting their own.

  Tokens are only ever sent over TLS: the library's operations attach the
  `authorization` metadata per checked-out channel (see `request_opts/1`), so a
  plaintext channel, such as the local emulator or a misconfigured pool, never
  receives one.

  ## Configuration

  To use Goth for authentication, add it to your supervision tree:

      children = [
        {Goth, name: MyApp.Goth, source: {:service_account, credentials}},
        # ... other children
      ]

  Then configure PubsubGrpc to use your Goth instance:

      config :pubsub_grpc, :goth, MyApp.Goth

  ### Token fetch timeout

  A token fetch (Goth or gcloud CLI) that takes longer than `:auth_timeout`
  milliseconds (a positive integer, default `10_000`) is aborted, and every caller
  waiting for it gets `{:error, %PubsubGrpc.Error{code: :deadline_exceeded}}`. A
  timed-out gcloud process is killed. The value is read at runtime; an invalid
  value fails application startup:

      config :pubsub_grpc, :auth_timeout, 5_000

  """

  require Logger

  alias PubsubGrpc.Auth.{Cache, CLI}
  alias PubsubGrpc.{Config, Error, Telemetry}

  # Cache gcloud CLI tokens for 50 minutes (tokens expire in 60 min)
  @cli_token_ttl_ms 50 * 60 * 1000
  @gcloud_args ["auth", "application-default", "print-access-token"]
  # OAuth2 access tokens are opaque base64url-like strings of ~100+ chars;
  # requiring 20 keeps status words such as "Done." from passing as a token.
  @min_token_length 20
  # The CLI kills gcloud itself this long before the Cache's own timeout fires, so
  # the in-task timeout path normally wins and the Cache timer is a backstop.
  @cli_deadline_margin 250

  @doc """
  Clears the cached authentication token.

  Useful when you need to force a token refresh, for example after
  rotating credentials. A fetch that is in flight when the cache is cleared
  still answers its waiting callers, but its token is not cached.

  A request that fails with `UNAUTHENTICATED` invalidates the token it carried
  (see `invalidate/1`).
  """
  @spec clear_cache() :: :ok
  def clear_cache, do: Cache.clear()

  @doc """
  Removes `token` from the cache if, and only if, it is the cached token.

  Used after a request carrying `token` was rejected with `UNAUTHENTICATED`, so a
  late rejection of an old token never evicts a newer one.
  """
  @spec invalidate(String.t()) :: :ok
  def invalidate(token) when is_binary(token), do: Cache.invalidate(token)

  @doc """
  Gets an authentication token for Google Cloud API calls.

  Returns a token string in the format "Bearer <token>". Tokens are cached
  in ETS and refreshed automatically when expired.

  ## Returns
  - `{:ok, "Bearer <token>"}` - Token retrieved successfully
  - `{:error, %PubsubGrpc.Error{}}` - Unable to get token (`:deadline_exceeded`
    if the fetch exceeded `:auth_timeout`)

  """
  @spec get_token() :: {:ok, String.t()} | {:error, Error.t()}
  def get_token do
    case Cache.lookup() do
      {:ok, token} -> {:ok, token}
      :miss -> Cache.refresh(&fetch_token/0, Config.auth_timeout())
    end
  end

  @doc """
  Gets request options including authentication metadata for `channel`.

  The token is attached only when `channel` uses TLS (scheme `https` with
  credentials). For a plaintext channel, such as the local emulator, returns
  `{:ok, []}` without fetching a token, so a token is never sent in cleartext,
  whatever the global configuration. Conversely, any TLS channel gets the token,
  including one from a pool passed as `:pool`: only point such pools at trusted
  Google endpoints.

  ## Returns
  - `{:ok, keyword()}` - Options to pass to gRPC stub functions
  - `{:error, %PubsubGrpc.Error{}}` - Authentication failed

  ## Examples

      PubsubGrpc.execute(fn channel ->
        {:ok, auth_opts} = PubsubGrpc.Auth.request_opts(channel)
        Google.Pubsub.V1.Publisher.Stub.get_topic(channel, request, auth_opts)
      end)

  """
  @spec request_opts(PubsubGrpc.Client.channel()) :: {:ok, keyword()} | {:error, Error.t()}
  def request_opts(%GRPC.Channel{} = channel) do
    if tls?(channel), do: token_opts(), else: {:ok, []}
  end

  @doc """
  Gets request options including authentication metadata, based on the global
  configuration rather than a channel.

  When the configured endpoint type is `:local` (emulator), returns `{:ok, []}`.
  Otherwise returns `{:ok, [metadata: %{"authorization" => token}]}`.

  Prefer `request_opts/1`: it decides per channel, so a token is never sent over
  a plaintext connection, e.g. from a pool other than the configured one.
  """
  @spec request_opts() :: {:ok, keyword()} | {:error, Error.t()}
  def request_opts do
    if Config.emulator?(), do: {:ok, []}, else: token_opts()
  end

  # Private functions

  defp tls?(%GRPC.Channel{scheme: "https", cred: cred}) when not is_nil(cred), do: true
  defp tls?(_channel), do: false

  defp token_opts do
    with {:ok, token} <- get_token() do
      {:ok, [metadata: %{"authorization" => token}]}
    end
  end

  # Runs inside a PubsubGrpc.TaskSupervisor task started by Auth.Cache, once per
  # real fetch (not per waiting caller).
  defp fetch_token do
    {source, fun} = token_source()
    Telemetry.auth_span(source, fun)
  end

  # `:token_fetcher` is an internal seam (used by tests): a 0-arity function
  # returning `{:ok, token, ttl_ms} | {:error, %PubsubGrpc.Error{}}`.
  defp token_source do
    case {Application.get_env(:pubsub_grpc, :token_fetcher),
          Application.get_env(:pubsub_grpc, :goth)} do
      {fetcher, _} when is_function(fetcher, 0) -> {:custom, fetcher}
      {_, nil} -> {:gcloud, &get_token_from_gcloud/0}
      {_, goth_name} -> {:goth, fn -> get_token_from_goth(goth_name) end}
    end
  end

  # Error details keep only a tag (module or atom): Goth errors and exceptions can
  # embed HTTP response bodies or call arguments.
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
      {:error, Error.new(:unauthenticated, "Goth authentication crashed", e.__struct__)}
  catch
    kind, _reason ->
      Logger.error("PubsubGrpc: Goth.fetch exited: #{kind}")
      {:error, Error.new(:unauthenticated, "Goth authentication crashed", kind)}
  end

  defp handle_goth_result({:ok, %{token: token, type: type} = result})
       when is_binary(token) and is_binary(type) do
    {:ok, "#{type} #{token}", goth_ttl_ms(result)}
  end

  defp handle_goth_result({:error, reason}) do
    # Goth was explicitly configured — do not silently fall back to gcloud CLI;
    # surface the failure so the caller knows their chosen auth path failed.
    tag = error_tag(reason)
    Logger.warning("PubsubGrpc: Goth.fetch failed (#{inspect(tag)})")

    {:error, Error.new(:unauthenticated, "Goth authentication failed", tag)}
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

  defp get_token_from_gcloud do
    case System.find_executable("gcloud") do
      nil ->
        Logger.error("PubsubGrpc: auth unavailable: gcloud not found")
        {:error, Error.new(:unauthenticated, "gcloud not found")}

      gcloud ->
        deadline = max(Config.auth_timeout() - @cli_deadline_margin, 1)
        gcloud |> CLI.run(@gcloud_args, deadline) |> handle_gcloud_result()
    end
  end

  defp handle_gcloud_result({:ok, output, 0}) do
    # stderr is merged into the output (warnings, update notices, "Done."): the
    # token is the last line that looks like an access token, and only such a
    # line may become a header.
    token =
      output
      |> String.split(["\r\n", "\n"])
      |> Enum.map(&String.trim/1)
      |> Enum.filter(&access_token?/1)
      |> List.last()

    if token do
      {:ok, "Bearer " <> token, @cli_token_ttl_ms}
    else
      Logger.error("PubsubGrpc: gcloud CLI output is not an access token")
      {:error, Error.new(:unauthenticated, "gcloud CLI output is not an access token")}
    end
  end

  defp handle_gcloud_result({:ok, output, exit_code}) do
    # Log raw output at debug only (may contain ADC paths, account emails).
    Logger.debug(fn -> "PubsubGrpc: gcloud output: #{String.trim(output)}" end)
    Logger.error("PubsubGrpc: gcloud CLI auth failed (exit #{exit_code})")

    {:error,
     Error.new(
       :unauthenticated,
       "gcloud CLI auth failed (exit #{exit_code})",
       {:gcloud_exit, exit_code}
     )}
  end

  defp handle_gcloud_result({:error, :timeout}) do
    Logger.error("PubsubGrpc: gcloud CLI auth timed out")
    {:error, Error.new(:deadline_exceeded, "auth token fetch timed out")}
  end

  defp handle_gcloud_result({:error, reason}) do
    Logger.error("PubsubGrpc: gcloud CLI auth failed (#{reason})")
    {:error, Error.new(:unauthenticated, "gcloud CLI auth failed", reason)}
  end

  defp access_token?(line) do
    byte_size(line) >= @min_token_length and
      Regex.match?(~r/\A[A-Za-z0-9._\-~+\/]+=*\z/, line)
  end

  # Best-effort tag for logging: an atom describing the error shape, never its contents.
  defp error_tag(%{__struct__: mod}), do: mod
  defp error_tag(reason) when is_atom(reason), do: reason
  defp error_tag({tag, _}) when is_atom(tag), do: tag
  defp error_tag(_), do: :unknown
end
