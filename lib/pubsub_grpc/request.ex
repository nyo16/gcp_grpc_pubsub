defmodule PubsubGrpc.Request do
  @moduledoc false
  # Request plumbing shared by `PubsubGrpc` and `PubsubGrpc.Schema`: per-call gRPC
  # options, resource paths, and pool checkout. Every public operation accepts the
  # common options `:timeout` and `:pool` and passes its `opts` through here.
  #
  # Authentication is decided per checked-out channel, never from global config:
  # the bearer token is attached only to TLS channels (see `Auth.request_opts/1`),
  # so a per-call `:pool` that points at a plaintext endpoint never receives it.

  alias PubsubGrpc.{Auth, Client, Config}

  @default_timeout 30_000

  @doc """
  Checks out a channel from `opts[:pool]` (default: the configured pool) and
  runs `call/3` on it.
  """
  @spec execute((PubsubGrpc.channel(), keyword() -> term()), keyword()) ::
          {:ok, term()} | {:error, term()}
  def execute(fun, opts) when is_function(fun, 2) do
    Client.execute(&call(&1, fun, opts), pool: opts[:pool], timeout: timeout(opts))
  end

  @doc """
  Builds the gRPC call options for `channel` (auth metadata only over TLS, plus
  the `:timeout`) and calls `fun.(channel, grpc_opts)`. If the call fails with
  UNAUTHENTICATED on the configured pool, the token it carried is invalidated
  (only if it is still the cached one).
  """
  @spec call(PubsubGrpc.channel(), (PubsubGrpc.channel(), keyword() -> term()), keyword()) ::
          term()
  def call(channel, fun, opts) do
    with {:ok, auth_opts} <- Auth.request_opts(channel) do
      result = fun.(channel, auth_opts ++ [timeout: timeout(opts)])
      if configured_pool?(opts), do: invalidate_rejected_token(result, auth_opts)
      result
    end
  end

  @doc """
  The per-call `:timeout`, or the `:default_timeout` app env (30s by default).
  """
  @spec timeout(keyword()) :: timeout()
  def timeout(opts) do
    opts[:timeout] || Application.get_env(:pubsub_grpc, :default_timeout, @default_timeout)
  end

  @spec project_path(String.t()) :: String.t()
  def project_path(project_id), do: "projects/#{project_id}"

  @spec topic_path(String.t(), String.t()) :: String.t()
  def topic_path(project_id, topic_id), do: "projects/#{project_id}/topics/#{topic_id}"

  @spec subscription_path(String.t(), String.t()) :: String.t()
  def subscription_path(project_id, subscription_id),
    do: "projects/#{project_id}/subscriptions/#{subscription_id}"

  @spec schema_path(String.t(), String.t()) :: String.t()
  def schema_path(project_id, schema_id), do: "projects/#{project_id}/schemas/#{schema_id}"

  # The token cache is shared by every pool. Only a rejection from the configured
  # (Google) endpoint may evict it; a custom pool's endpoint answering
  # UNAUTHENTICATED must not force refetches for everyone.
  defp configured_pool?(opts), do: opts[:pool] in [nil, Config.pool_name()]

  # UNAUTHENTICATED (16): the token was rejected (revoked, rotated or expired
  # early). Drop it from the cache, unless a newer token has replaced it already.
  defp invalidate_rejected_token({:error, %GRPC.RPCError{status: 16}}, auth_opts) do
    case auth_opts[:metadata] do
      %{"authorization" => token} -> Auth.invalidate(token)
      _ -> :ok
    end
  end

  defp invalidate_rejected_token(_result, _auth_opts), do: :ok
end
