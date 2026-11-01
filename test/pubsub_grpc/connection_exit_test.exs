defmodule PubsubGrpc.ConnectionExitTest do
  # Global state: app env (:token_fetcher), the token cache, telemetry handlers and
  # the connection process of a dedicated pool.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias PubsubGrpc.{Auth, Error, LogRedactor, Request}
  alias PubsubGrpc.Proto.Google.Pubsub.V1, as: PubsubV1
  alias PubsubV1.Publisher.Stub, as: PublisherStub

  @token "Bearer ya29.REGRESSION"

  # Regression for C1 (2026-10-31 audit): when grpc's gun connection process does
  # not answer `GenServer.call/2` (busy for 5 s, or dead), the exit reason embeds the
  # request headers, bearer token included. It used to escape as an exit and be
  # logged verbatim by `GRPC.Telemetry`.
  describe "connection process exits" do
    @describetag :integration

    setup do
      saved = Application.fetch_env(:pubsub_grpc, :token_fetcher)
      Application.put_env(:pubsub_grpc, :token_fetcher, fn -> {:ok, @token, 3_600_000} end)
      Auth.clear_cache()

      handler_id = {__MODULE__, make_ref()}

      :telemetry.attach(
        handler_id,
        [:pubsub_grpc, :request, :stop],
        &__MODULE__.handle_stop/4,
        self()
      )

      on_exit(fn ->
        :telemetry.detach(handler_id)

        case saved do
          {:ok, fetcher} -> Application.put_env(:pubsub_grpc, :token_fetcher, fetcher)
          :error -> Application.delete_env(:pubsub_grpc, :token_fetcher)
        end

        Auth.clear_cache()
      end)

      pool = :"connection_exit_pool_#{System.unique_integer([:positive])}"

      {:ok, config} =
        GrpcConnectionPool.Config.local(
          host: "localhost",
          port: 8085,
          pool_name: pool,
          pool_size: 1
        )

      start_supervised!({GrpcConnectionPool, config})
      :ok = GrpcConnectionPool.await_ready(pool, 5_000)

      {:ok, channel} = GrpcConnectionPool.get_channel(pool)
      conn_pid = channel.adapter_payload.conn_pid
      :sys.suspend(conn_pid)
      on_exit(fn -> if Process.alive?(conn_pid), do: :sys.resume(conn_pid) end)

      %{pool: pool}
    end

    test "a busy connection process makes an operation return :unavailable", %{pool: pool} do
      log =
        capture_log(fn ->
          assert {:error, %Error{code: :unavailable, details: :timeout}} =
                   PubsubGrpc.publish_message("test-project-id", "c1-topic", "SECRET", %{},
                     pool: pool,
                     timeout: 1_000
                   )
        end)

      assert log =~ "GenServer.call"
      assert_received {:request_stop, %{operation: :publish, result: {:error, :unavailable}}}
    end

    # Both calls run under the same suspension, so the test waits for grpc's 5 s
    # call timeout once.
    test "execute/2 returns :unavailable and no bearer token reaches the log", %{pool: pool} do
      log =
        capture_log(fn ->
          results =
            [
              # Custom metadata passed by an execute/2 callback.
              fn channel -> publish(channel, metadata: %{"authorization" => "Bearer ya29.X"}) end,
              # The cached token, attached because the channel is TLS-shaped.
              fn channel -> Request.call(tls(channel), &publish/2, []) end
            ]
            |> Enum.map(fn callback ->
              Task.async(fn -> PubsubGrpc.execute(callback, pool: pool) end)
            end)
            |> Task.await_many(15_000)

          assert [{:error, %Error{code: :unavailable}}, {:error, %Error{code: :unavailable}}] =
                   results
        end)

      assert log =~ "Bearer [REDACTED]"
      refute log =~ "ya29.X"
      refute log =~ "ya29.REGRESSION"
    end
  end

  # Synthetic exits with the exact shape `GenServer.call/3` produces, raised from an
  # execute/2 callback on a checked-out channel.
  describe "which exits become :unavailable" do
    @describetag :integration

    test "exits of calls to grpc's gun connection process, tagged by reason" do
      headers = [{"authorization", "Bearer ya29.SECRET"}]

      for {reason, message, tag} <- [
            {:timeout, {:request, "/google.pubsub.v1.Publisher/Publish", headers, "body"},
             :timeout},
            {:noproc, {:open_stream, "/google.pubsub.v1.Subscriber/StreamingPull", headers},
             :noproc},
            {{:shutdown, :closed}, {:send_data, make_ref(), :fin, "data"}, :shutdown},
            {{:EXIT, :weird}, {:cancel, make_ref()}, :unknown}
          ] do
        assert {:error, %Error{code: :unavailable, details: ^tag} = error} =
                 PubsubGrpc.execute(fn _channel -> call_exit(reason, message) end)

        refute inspect(error, structs: false) =~ "SECRET"
      end
    end

    test "other GenServer.call exits from an execute/2 callback are re-raised unchanged" do
      reason = {:timeout, {GenServer, :call, [self(), :my_app_request, 5_000]}}

      assert catch_exit(PubsubGrpc.execute(fn _channel -> exit(reason) end)) == reason
    end
  end

  describe "LogRedactor installation" do
    @describetag :integration

    setup do
      saved = Application.fetch_env(:pubsub_grpc, :redact_grpc_logs)

      on_exit(fn ->
        case saved do
          {:ok, value} -> Application.put_env(:pubsub_grpc, :redact_grpc_logs, value)
          :error -> Application.delete_env(:pubsub_grpc, :redact_grpc_logs)
        end

        restart_app()
      end)
    end

    test "installed at start, removed at stop, skipped with :redact_grpc_logs false" do
      assert redactor_installed?()
      assert :ok = LogRedactor.install()
      assert Enum.count(primary_filter_ids(), &(&1 == :pubsub_grpc_redact_bearer)) == 1

      capture_log(fn -> :ok = Application.stop(:pubsub_grpc) end)
      refute redactor_installed?()

      Application.put_env(:pubsub_grpc, :redact_grpc_logs, false)
      restart_app()
      refute redactor_installed?()

      Application.delete_env(:pubsub_grpc, :redact_grpc_logs)
      restart_app()
      assert redactor_installed?()
    end
  end

  describe "LogRedactor.filter/2" do
    @grpc_meta %{mfa: {GRPC.Telemetry, :client_span, 3}}

    test "redacts bearer tokens in string messages logged by GRPC.Telemetry" do
      event =
        event(@grpc_meta, {:string, ["headers: ", ~s({"authorization", "Bearer ya29.a-b_c"})]})

      assert %{msg: {:string, string}} = LogRedactor.filter(event, [])
      assert string == ~s(headers: {"authorization", "Bearer [REDACTED]"})
    end

    test "formats and redacts format/args messages logged by GRPC.Telemetry" do
      event = event(@grpc_meta, {~c"exit: ~p", [{"authorization", "bearer ya29.tok=="}]})

      assert %{msg: {:string, string}} = LogRedactor.filter(event, [])
      assert string == ~s(exit: {<<"authorization">>,<<"Bearer [REDACTED]">>})
    end

    test "ignores events from other modules and report messages" do
      msg = {:string, "Bearer ya29.keep"}

      assert :ignore = LogRedactor.filter(event(%{mfa: {MyApp, :run, 0}}, msg), [])
      assert :ignore = LogRedactor.filter(event(%{}, msg), [])
      assert :ignore = LogRedactor.filter(event(@grpc_meta, {:report, [token: "x"]}), [])
    end

    test "an event that cannot be formatted is withheld instead of crashing the filter" do
      # A format/args mismatch makes :io_lib.format/2 raise; a raising filter would be
      # removed by :logger for good.
      event = event(@grpc_meta, {~c"~p ~p", ["Bearer ya29.leak"]})

      assert %{msg: {:string, string}} = LogRedactor.filter(event, [])
      assert string =~ "withheld"
      refute string =~ "ya29.leak"
    end
  end

  @doc false
  def handle_stop(_event, _measurements, metadata, test_pid) do
    send(test_pid, {:request_stop, metadata})
  end

  defp event(meta, msg), do: %{level: :error, meta: meta, msg: msg}

  defp call_exit(reason, message),
    do: exit({reason, {GenServer, :call, [self(), message, 5_000]}})

  defp primary_filter_ids, do: for({id, _} <- :logger.get_primary_config().filters, do: id)
  defp redactor_installed?, do: :pubsub_grpc_redact_bearer in primary_filter_ids()

  defp restart_app do
    capture_log(fn ->
      _ = Application.stop(:pubsub_grpc)
      {:ok, _} = Application.ensure_all_started(:pubsub_grpc)
    end)

    :ok = GrpcConnectionPool.await_ready(PubsubGrpc.ConnectionPool, 5_000)
  end

  defp tls(channel), do: %{channel | scheme: "https", cred: %GRPC.Credential{ssl: []}}

  defp publish(channel, grpc_opts) do
    request = %PubsubV1.PublishRequest{
      topic: "projects/test-project-id/topics/c1-topic",
      messages: [%PubsubV1.PubsubMessage{data: "SECRET"}]
    }

    PublisherStub.publish(channel, request, grpc_opts)
  end
end
