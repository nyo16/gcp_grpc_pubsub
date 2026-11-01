defmodule PubsubGrpc.LogRedactor do
  @moduledoc false
  # A `:logger` primary filter that redacts bearer tokens from grpc's client log.
  #
  # When the gun connection process exits during a call, `GRPC.Telemetry.client_span/3`
  # logs the exit at `:error` before re-raising it. The exit reason embeds the call
  # message, i.e. the request headers including `authorization: Bearer <token>`.
  # That log happens before `PubsubGrpc.Client` can catch the exit, so it is
  # redacted here. Only events logged from `GRPC.Telemetry` are touched; every
  # other event is passed through untouched (`:ignore`).
  #
  # Installed by `PubsubGrpc.Application` unless `config :pubsub_grpc,
  # :redact_grpc_logs, false`.

  @filter_id :pubsub_grpc_redact_bearer

  @spec install() :: :ok
  def install do
    case :logger.add_primary_filter(@filter_id, {&__MODULE__.filter/2, []}) do
      :ok -> :ok
      {:error, {:already_exist, @filter_id}} -> :ok
    end
  end

  @spec uninstall() :: :ok
  def uninstall do
    _ = :logger.remove_primary_filter(@filter_id)
    :ok
  end

  # A filter that raises is removed by :logger for good, which would silently turn
  # redaction off for the rest of the VM's life. So a grpc event that cannot be
  # redacted is kept, but with its message replaced.
  @unredactable "PubsubGrpc: grpc log message withheld (it could not be redacted)"

  @spec filter(:logger.log_event(), term()) :: :logger.filter_return()
  def filter(%{meta: %{mfa: {GRPC.Telemetry, _, _}}} = event, _extra) do
    redact_event(event)
  rescue
    _ -> %{event | msg: {:string, @unredactable}}
  end

  def filter(_event, _extra), do: :ignore

  defp redact_event(%{msg: {:string, string}} = event) do
    %{event | msg: {:string, redact(IO.chardata_to_string(string))}}
  end

  defp redact_event(%{msg: {format, args}} = event) when format != :report and is_list(args) do
    formatted = format |> :io_lib.format(args) |> IO.chardata_to_string()
    %{event | msg: {:string, redact(formatted)}}
  end

  defp redact_event(_event), do: :ignore

  @doc false
  @spec redact(String.t()) :: String.t()
  def redact(string) do
    # Compiled per call on purpose: this only runs for grpc's rare error logs, and
    # a module-attribute regex is recompiled on every use on OTP 28+.
    Regex.replace(~r/bearer\s+[A-Za-z0-9\-._~+\/]+=*/i, string, "Bearer [REDACTED]")
  end
end
