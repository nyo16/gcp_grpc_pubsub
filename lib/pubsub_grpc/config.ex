defmodule PubsubGrpc.Config do
  @moduledoc false
  # Single source of truth for the connection-pool configuration.
  #
  # `resolve/1` turns the `:pubsub_grpc` application env into a resolved map and
  # raises `ArgumentError` for invalid or unsafe configuration. It does no logging
  # and writes no state of its own, but it is not pure: for production endpoints
  # it reads the OS trust store (`:public_key.cacerts_get/0`, which OTP caches in
  # its own persistent_term). `PubsubGrpc.Application.start/2` resolves once and
  # stores the result with `put/1` in `:persistent_term`. The read functions fall
  # back to resolving from the application env when nothing is stored (e.g. the
  # application is not started).

  @default_pool_name PubsubGrpc.ConnectionPool
  @default_auth_timeout 10_000
  @default_legacy_pool_size 5
  @pubsub_host "pubsub.googleapis.com"
  @key {__MODULE__, :resolved}

  @type endpoint_type :: :local | :production

  @type resolved :: %{
          pool_config: GrpcConnectionPool.Config.t(),
          pool_name: atom(),
          endpoint_type: endpoint_type(),
          source: :app_env | :legacy
        }

  @spec default_pool_name() :: atom()
  def default_pool_name, do: @default_pool_name

  # Readers

  @spec pool_config() :: GrpcConnectionPool.Config.t()
  def pool_config, do: current().pool_config

  @spec pool_name() :: atom()
  def pool_name do
    current().pool_name
  rescue
    # Unresolvable config (ArgumentError), or the trust store failed to load
    # (ErlangError {:failed_load_cacerts, _}): use the default name.
    _ in [ArgumentError, ErlangError] -> @default_pool_name
  end

  @spec endpoint_type() :: endpoint_type()
  def endpoint_type do
    current().endpoint_type
  rescue
    # Unresolvable config: assume production, so authentication is never skipped.
    _ in [ArgumentError, ErlangError] -> :production
  end

  @doc """
  The `:auth_timeout` app env in milliseconds. `resolve/1` rejects an invalid
  value at startup; if one is set later (or the application is not started), the
  default (10_000) is used instead.
  """
  @spec auth_timeout() :: pos_integer()
  def auth_timeout do
    case Application.get_env(:pubsub_grpc, :auth_timeout, @default_auth_timeout) do
      timeout when is_integer(timeout) and timeout > 0 -> timeout
      _invalid -> @default_auth_timeout
    end
  end

  @spec emulator?() :: boolean()
  def emulator?, do: endpoint_type() == :local

  @spec put(resolved()) :: :ok
  def put(resolved) do
    # persistent_term writes trigger a global GC: skip if unchanged.
    if :persistent_term.get(@key, nil) != resolved, do: :persistent_term.put(@key, resolved)
    :ok
  end

  defp current do
    case :persistent_term.get(@key, nil) do
      nil -> resolve(Application.get_all_env(:pubsub_grpc))
      resolved -> resolved
    end
  end

  # Resolution

  @doc """
  Resolves the `:pubsub_grpc` application env (a keyword list, as returned by
  `Application.get_all_env/1`). Raises `ArgumentError` on invalid configuration.
  """
  @spec resolve(keyword()) :: resolved()
  def resolve(env) do
    {source, pool_config} =
      case Keyword.fetch(env, GrpcConnectionPool) do
        {:ok, opts} -> {:app_env, from_app_env!(opts, env)}
        :error -> {:legacy, from_legacy!(env)}
      end

    endpoint_type = if pool_config.endpoint.type == :local, do: :local, else: :production
    ensure_tls!(pool_config, endpoint_type)
    ensure_auth_timeout!(env)

    %{
      pool_config: pool_config,
      pool_name: pool_config.pool.name,
      endpoint_type: endpoint_type,
      source: source
    }
  end

  @doc """
  TLS options for production endpoints: `GrpcConnectionPool`'s verified defaults
  (system CAs, peer and hostname verification), with `:ssl_opts` from `env`
  merged over them.
  """
  @spec production_ssl_opts(keyword()) :: keyword()
  def production_ssl_opts(env) do
    user_opts = Keyword.get(env, :ssl_opts, [])
    defaults = GrpcConnectionPool.Config.default_production_ssl()

    # `cacerts` takes precedence over `cacertfile` in :ssl, so a user-supplied CA
    # file would otherwise be silently ignored.
    defaults =
      if Keyword.has_key?(user_opts, :cacertfile),
        do: Keyword.delete(defaults, :cacerts),
        else: defaults

    Keyword.merge(defaults, user_opts)
  end

  defp from_app_env!(opts, env) when is_list(opts) do
    endpoint = Keyword.get(opts, :endpoint, [])
    pool = Keyword.get(opts, :pool, [])

    opts =
      opts
      |> Keyword.put(:endpoint, with_default_ssl(endpoint, env))
      |> Keyword.put(:pool, Keyword.put_new(pool, :name, @default_pool_name))

    case GrpcConnectionPool.Config.new(opts) do
      {:ok, config} -> config
      {:error, reason} -> raise ArgumentError, invalid_app_env_message(reason)
    end
  end

  defp from_app_env!(_opts, _env) do
    raise ArgumentError, invalid_app_env_message("expected a keyword list")
  end

  # Production endpoints without TLS settings, and any endpoint with an empty
  # `ssl: []`, get the verified defaults.
  defp with_default_ssl(endpoint, env) do
    type = Keyword.get(endpoint, :type, :production)

    case {type, Keyword.get(endpoint, :ssl), Keyword.get(endpoint, :credentials)} do
      {_, [], _} -> Keyword.put(endpoint, :ssl, production_ssl_opts(env))
      {:production, nil, nil} -> Keyword.put(endpoint, :ssl, production_ssl_opts(env))
      _ -> endpoint
    end
  end

  defp from_legacy!(env) do
    pool_size = Keyword.get(env, :default_pool_size, @default_legacy_pool_size)

    opts =
      case Keyword.get(env, :emulator) do
        emulator when is_list(emulator) ->
          [
            endpoint: [
              type: :local,
              host: emulator[:host] || "localhost",
              port: emulator[:port] || 8085
            ],
            pool: [size: pool_size, name: @default_pool_name],
            # Disable pinging for emulator
            connection: [ping_interval: nil, health_check: true]
          ]

        _ ->
          [
            endpoint: [
              type: :production,
              host: @pubsub_host,
              port: 443,
              ssl: production_ssl_opts(env)
            ],
            pool: [size: pool_size, name: @default_pool_name]
          ]
      end

    case GrpcConnectionPool.Config.new(opts) do
      {:ok, config} ->
        config

      {:error, reason} ->
        raise ArgumentError,
              "PubsubGrpc: invalid legacy configuration (:emulator / :default_pool_size): " <>
                "#{reason}. Fix those values or configure `config :pubsub_grpc, GrpcConnectionPool, ...`."
    end
  end

  defp ensure_auth_timeout!(env) do
    case Keyword.fetch(env, :auth_timeout) do
      :error ->
        :ok

      {:ok, timeout} when is_integer(timeout) and timeout > 0 ->
        :ok

      {:ok, other} ->
        raise ArgumentError,
              "PubsubGrpc: invalid `config :pubsub_grpc, :auth_timeout, #{inspect(other)}`: " <>
                "it must be a positive integer (milliseconds). Remove it to use the " <>
                "default (#{@default_auth_timeout})."
    end
  end

  defp ensure_tls!(_config, :local), do: :ok

  defp ensure_tls!(%{endpoint: endpoint}, :production) do
    if endpoint.ssl in [nil, false] and is_nil(endpoint.credentials) do
      raise ArgumentError,
            "PubsubGrpc: refusing to connect to #{endpoint.host}:#{endpoint.port} " <>
              "(endpoint type #{inspect(endpoint.type)}) without TLS: authentication tokens " <>
              "would be sent in plaintext. Set `ssl: [...]` or `credentials: ...` on the " <>
              "endpoint, use `type: :production` (verified TLS by default), or use " <>
              "`type: :local` for a plaintext emulator connection."
    end

    :ok
  end

  # `reason` is a binary: GrpcConnectionPool.Config.new/1 is specced
  # `{:error, String.t()}` (it rescues and returns "Invalid configuration: ..."),
  # and Dialyzer flags a non-binary fallback clause as unreachable.
  defp invalid_app_env_message(reason) do
    "PubsubGrpc: invalid `config :pubsub_grpc, GrpcConnectionPool` (#{reason}). " <>
      "Fix it, or remove the key to use the legacy :emulator / production defaults."
  end
end
