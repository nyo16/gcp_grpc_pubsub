defmodule PubsubGrpc.Connection do
  @moduledoc """
  Documentation for `PubsubGrpc.Connection`.
  """
  use GenServer

  def start_link(args \\ []) do
    GenServer.start_link(__MODULE__, args)
  end

  @impl true
  def init(_) do
    Process.flag(:trap_exit, true)

    connect()
  end

  @impl true
  def handle_call(:get_connection, _from, channel) do
    {:reply, channel, channel}
  end

  @impl true
  def handle_info({:EXIT, _from, reason}, channel) do
    disconnect(channel)
    {:stop, reason, channel}
  end

  def handle_info(_info, channel) do
    {:noreply, channel}
  end

  @impl true
  def terminate(_reason, channel) do
    disconnect(channel)
    channel
  end

  defp connect() do
    emulator = Application.get_env(:pubsub_grpc, :emulator)

    case emulator do
      nil ->
        ssl_opts =
          Application.get_env(:google_grpc_pubsub, :ssl_opts, [])

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

  defp disconnect(channel) do
    GRPC.Stub.disconnect(channel)
  end
end
