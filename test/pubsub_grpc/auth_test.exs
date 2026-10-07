defmodule PubsubGrpc.AuthTest do
  use ExUnit.Case

  import ExUnit.CaptureLog
  import PubsubGrpc.Eventually, only: [eventually: 1]

  alias PubsubGrpc.{Auth, Config, Error, Request}
  alias PubsubGrpc.Auth.{Cache, CLI}

  @env_keys [:token_fetcher, :goth, :auth_timeout]

  setup do
    saved = Map.new(@env_keys, &{&1, Application.fetch_env(:pubsub_grpc, &1)})
    Enum.each(@env_keys, &Application.delete_env(:pubsub_grpc, &1))
    Auth.clear_cache()

    on_exit(fn ->
      Enum.each(saved, fn
        {key, {:ok, value}} -> Application.put_env(:pubsub_grpc, key, value)
        {key, :error} -> Application.delete_env(:pubsub_grpc, key)
      end)

      Auth.clear_cache()
    end)

    :ok
  end

  describe "request_opts/0" do
    setup :restore_config_on_exit

    setup do
      test_pid = self()

      put_fetcher(fn ->
        send(test_pid, :token_fetched)
        {:ok, "Bearer t", 60_000}
      end)

      :ok
    end

    test "returns {:ok, []} with the legacy :emulator config" do
      assert Application.get_env(:pubsub_grpc, :emulator) != nil
      assert {:ok, []} = Auth.request_opts()
      refute_received :token_fetched
    end

    test "a type: :local endpoint skips auth without any :emulator key" do
      Application.delete_env(:pubsub_grpc, :emulator)

      Config.put(
        Config.resolve([
          {GrpcConnectionPool, [endpoint: [type: :local, host: "localhost", port: 8085]]}
        ])
      )

      assert {:ok, []} = Auth.request_opts()
      refute_received :token_fetched
    end

    test "a production endpoint requests a token even if :emulator is set" do
      assert Application.get_env(:pubsub_grpc, :emulator) != nil
      Config.put(Config.resolve([]))

      assert {:ok, [metadata: %{"authorization" => "Bearer t"}]} = Auth.request_opts()
      assert_received :token_fetched
    end

    test "Config readers fall back to the application env when nothing is stored" do
      :persistent_term.erase({Config, :resolved})

      assert Config.pool_name() == PubsubGrpc.ConnectionPool
      assert Config.emulator?()
      assert {:ok, []} = Auth.request_opts()
    end
  end

  describe "auth failure on a TLS channel" do
    test "a token fetch error is returned without calling the RPC" do
      # Auth is decided per checked-out channel: only TLS channels need a token.
      # No TLS endpoint is available locally, so call the per-channel step directly.
      tls_channel = %GRPC.Channel{scheme: "https", cred: %GRPC.Credential{ssl: []}}
      put_fetcher(fn -> {:error, Error.new(:unauthenticated, "no credentials")} end)

      result =
        Request.call(tls_channel, fn _channel, _opts -> flunk("RPC must not be called") end, [])

      assert {:error, %Error{code: :unauthenticated, message: "no credentials"}} = result

      # What the public operations return for it (Client wraps the callback result).
      assert {:error, %Error{code: :unauthenticated, message: "no credentials"}} =
               PubsubGrpc.Result.unwrap({:ok, result})
    end
  end

  describe "token table" do
    test "is :protected and owned by Auth.Cache" do
      assert :ets.info(Cache.table(), :protection) == :protected
      assert :ets.info(Cache.table(), :owner) == Process.whereis(Cache)

      assert_raise ArgumentError, fn ->
        :ets.insert(Cache.table(), {:token, "Bearer forged", :infinity})
      end
    end
  end

  describe "clear_cache/0" do
    test "removes the cached token and is idempotent" do
      put_fetcher(fn -> {:ok, "Bearer cached", 60_000} end)
      assert {:ok, "Bearer cached"} = Auth.get_token()
      assert {:ok, "Bearer cached"} = Cache.lookup()

      assert :ok = Auth.clear_cache()
      assert :miss = Cache.lookup()
      assert :ok = Auth.clear_cache()
    end
  end

  describe "get_token/0 caching" do
    test "fetches on a miss and serves later calls from the cache" do
      counter = :counters.new(1, [])

      put_fetcher(fn ->
        :counters.add(counter, 1, 1)
        {:ok, "Bearer t1", 60_000}
      end)

      assert {:ok, "Bearer t1"} = Auth.get_token()
      assert {:ok, "Bearer t1"} = Auth.get_token()
      assert :counters.get(counter, 1) == 1
    end

    test "refetches once the TTL has expired" do
      counter = :counters.new(1, [])

      put_fetcher(fn ->
        :counters.add(counter, 1, 1)
        {:ok, "Bearer t#{:counters.get(counter, 1)}", 0}
      end)

      assert {:ok, "Bearer t1"} = Auth.get_token()
      assert {:ok, "Bearer t2"} = Auth.get_token()
      assert :counters.get(counter, 1) == 2
    end

    test "returns fetch errors without caching them" do
      counter = :counters.new(1, [])

      put_fetcher(fn ->
        :counters.add(counter, 1, 1)
        {:error, Error.new(:unauthenticated, "nope")}
      end)

      assert {:error, %Error{code: :unauthenticated, message: "nope"}} = Auth.get_token()
      assert {:error, %Error{code: :unauthenticated}} = Auth.get_token()
      assert :counters.get(counter, 1) == 2
    end

    test "rejects an unexpected fetcher result without echoing it" do
      put_fetcher(fn -> {:ok, "Bearer secret-token"} end)

      assert {:error, %Error{code: :unauthenticated} = error} = Auth.get_token()
      refute inspect(error, structs: false) =~ "secret-token"
      assert :miss = Cache.lookup()
    end
  end

  describe "single-flight refresh" do
    test "50 concurrent callers trigger exactly one fetch and one auth span" do
      counter = :counters.new(1, [])
      put_fetcher(blocking_fetcher(counter, {:ok, "Bearer shared", 60_000}))
      attach_auth_stop_handler()

      callers = for _ <- 1..50, do: Task.async(&Auth.get_token/0)
      assert_receive {:fetch_started, fetch_pid}
      eventually(fn -> waiter_count() == 50 end)
      send(fetch_pid, :release)

      results = Task.await_many(callers)
      assert Enum.all?(results, &(&1 == {:ok, "Bearer shared"}))
      assert :counters.get(counter, 1) == 1

      assert_receive {:auth_stop, %{source: :custom, result: :ok}}
      refute_receive {:auth_stop, _}, 50
    end

    test "a fetch exceeding :auth_timeout releases every waiter with :deadline_exceeded" do
      Application.put_env(:pubsub_grpc, :auth_timeout, 100)
      put_fetcher(blocking_fetcher(:counters.new(1, []), :never_released))

      callers = for _ <- 1..10, do: Task.async(&Auth.get_token/0)
      assert_receive {:fetch_started, fetch_pid}
      ref = Process.monitor(fetch_pid)

      for result <- Task.await_many(callers) do
        assert {:error, %Error{code: :deadline_exceeded}} = result
      end

      # The timed-out fetch task is terminated.
      assert_receive {:DOWN, ^ref, :process, ^fetch_pid, _}
      eventually(fn -> Task.Supervisor.children(PubsubGrpc.TaskSupervisor) == [] end)
    end

    test "callers get an error, not an exit, when Auth.Cache dies mid-flight" do
      put_fetcher(blocking_fetcher(:counters.new(1, []), :never_released))
      old_cache = Process.whereis(Cache)

      caller = Task.async(&Auth.get_token/0)
      assert_receive {:fetch_started, fetch_pid}
      eventually(fn -> waiter_count() == 1 end)

      Process.exit(old_cache, :kill)

      assert {:error, %Error{code: :unauthenticated}} = Task.await(caller)

      Process.exit(fetch_pid, :kill)
      eventually(fn -> Process.whereis(Cache) not in [nil, old_cache] end)
      assert :ets.info(Cache.table(), :owner) == Process.whereis(Cache)
    end

    test "a fetch task killed from outside releases every waiter at once" do
      # Far beyond the assertion below: the waiters must not wait for the timer.
      Application.put_env(:pubsub_grpc, :auth_timeout, 10_000)
      counter = :counters.new(1, [])
      put_fetcher(blocking_fetcher(counter, :never_released))

      callers = for _ <- 1..5, do: Task.async(&Auth.get_token/0)
      assert_receive {:fetch_started, fetch_pid}
      eventually(fn -> waiter_count() == 5 end)

      Process.exit(fetch_pid, :kill)
      results = Task.await_many(callers, 5_000)

      for result <- results do
        assert {:error, %Error{code: :unauthenticated, message: "auth token fetch crashed"}} =
                 result
      end

      assert %{inflight: nil} = :sys.get_state(Cache)

      # The next miss starts a new fetch.
      put_fetcher(fn -> {:ok, "Bearer after-crash", 60_000} end)
      assert {:ok, "Bearer after-crash"} = Auth.get_token()
      assert :counters.get(counter, 1) == 1
    end

    test "a raising fetcher is an :unauthenticated error that does not echo the exception" do
      put_fetcher(fn -> raise "Bearer ya29.leaked-secret" end)

      assert {:error, %Error{code: :unauthenticated, details: RuntimeError} = error} =
               Auth.get_token()

      refute inspect(error, structs: false) =~ "leaked-secret"
      assert :miss = Cache.lookup()
    end
  end

  describe "invalidation on UNAUTHENTICATED" do
    @tls_channel %GRPC.Channel{scheme: "https", cred: %GRPC.Credential{ssl: []}}
    @unauthenticated {:error, %GRPC.RPCError{status: 16, message: "token revoked"}}

    test "other gRPC errors keep the cached token" do
      put_fetcher(fn -> {:ok, "Bearer cached", 60_000} end)
      not_found = {:error, %GRPC.RPCError{status: 5, message: "nf"}}

      assert ^not_found = Request.call(@tls_channel, fn _ch, _opts -> not_found end, [])
      assert {:ok, "Bearer cached"} = Cache.lookup()
    end

    test "a request rejected with status 16 invalidates the token it carried" do
      put_fetcher(fn -> {:ok, "Bearer revoked", 60_000} end)
      test_pid = self()

      assert @unauthenticated =
               Request.call(
                 @tls_channel,
                 fn _ch, opts ->
                   send(test_pid, {:sent, opts[:metadata]})
                   @unauthenticated
                 end,
                 []
               )

      assert_received {:sent, %{"authorization" => "Bearer revoked"}}
      assert :miss = Cache.lookup()
    end

    test "status 16 from a custom pool does not evict the shared token" do
      put_fetcher(fn -> {:ok, "Bearer shared", 60_000} end)

      assert @unauthenticated =
               Request.call(@tls_channel, fn _ch, _opts -> @unauthenticated end,
                 pool: :some_custom_tls_pool
               )

      assert {:ok, "Bearer shared"} = Cache.lookup()

      # The configured pool, named explicitly, still invalidates.
      assert @unauthenticated =
               Request.call(@tls_channel, fn _ch, _opts -> @unauthenticated end,
                 pool: Config.pool_name()
               )

      assert :miss = Cache.lookup()
    end

    test "a late rejection of an old token does not evict a newer one" do
      put_fetcher(fn -> {:ok, "Bearer new", 60_000} end)
      assert {:ok, "Bearer new"} = Auth.get_token()

      assert :ok = Auth.invalidate("Bearer old")
      assert {:ok, "Bearer new"} = Cache.lookup()

      assert :ok = Auth.invalidate("Bearer new")
      assert :miss = Cache.lookup()
    end
  end

  describe "clear during an in-flight fetch" do
    test "the fetch answers its waiters but its token is not cached" do
      put_fetcher(blocking_fetcher(:counters.new(1, []), {:ok, "Bearer stale", 60_000}))

      caller = Task.async(&Auth.get_token/0)
      assert_receive {:fetch_started, fetch_pid}
      eventually(fn -> waiter_count() == 1 end)

      assert :ok = Auth.clear_cache()
      send(fetch_pid, :release)

      assert {:ok, "Bearer stale"} = Task.await(caller)
      assert :miss = Cache.lookup()

      # A fetch started after the clear is cached again.
      put_fetcher(fn -> {:ok, "Bearer fresh", 60_000} end)
      assert {:ok, "Bearer fresh"} = Auth.get_token()
      assert {:ok, "Bearer fresh"} = Cache.lookup()
    end

    test "callers arriving after the clear start a new fetch instead of joining the old one" do
      counter = :counters.new(1, [])
      test_pid = self()

      put_fetcher(fn ->
        :counters.add(counter, 1, 1)
        n = :counters.get(counter, 1)
        send(test_pid, {:fetch_started, n, self()})

        receive do
          :release -> {:ok, "Bearer #{n}", 60_000}
        end
      end)

      before_clear = Task.async(&Auth.get_token/0)
      assert_receive {:fetch_started, 1, first_fetch}
      eventually(fn -> waiter_count() == 1 end)

      assert :ok = Auth.clear_cache()

      after_clear = Task.async(&Auth.get_token/0)
      assert_receive {:fetch_started, 2, second_fetch}

      send(second_fetch, :release)
      assert {:ok, "Bearer 2"} = Task.await(after_clear)

      # The pre-clear fetch still answers its own caller, without being cached.
      send(first_fetch, :release)
      assert {:ok, "Bearer 1"} = Task.await(before_clear)

      assert :counters.get(counter, 1) == 2
      assert {:ok, "Bearer 2"} = Cache.lookup()
      assert %{inflight: nil, stale: stale} = :sys.get_state(Cache)
      assert stale == %{}
    end
  end

  describe "token only over TLS (per channel)" do
    setup do
      original = Config.resolve(Application.get_all_env(:pubsub_grpc))
      on_exit(fn -> Config.put(original) end)

      # Global config: production (TLS), so request_opts/0 would attach a token.
      Config.put(Config.resolve([]))

      test_pid = self()

      put_fetcher(fn ->
        send(test_pid, :token_fetched)
        {:ok, "Bearer secret-token", 60_000}
      end)

      :ok
    end

    test "request_opts/1 attaches the token to a TLS channel" do
      assert {:ok, [metadata: %{"authorization" => "Bearer secret-token"}]} =
               Auth.request_opts(%GRPC.Channel{scheme: "https", cred: %GRPC.Credential{ssl: []}})
    end

    test "request_opts/1 never fetches or attaches a token for a plaintext channel" do
      for channel <- [
            %GRPC.Channel{scheme: "http", cred: nil},
            %GRPC.Channel{scheme: "https", cred: nil},
            %GRPC.Channel{scheme: "http", cred: %GRPC.Credential{ssl: []}}
          ] do
        assert {:ok, []} = Auth.request_opts(channel)
      end

      refute_received :token_fetched
    end

    @tag :integration
    test "a plaintext custom pool gets no authorization metadata despite production config" do
      pool = :"auth_test_plaintext_pool_#{System.unique_integer([:positive])}"

      {:ok, config} =
        GrpcConnectionPool.Config.local(
          host: "localhost",
          port: 8085,
          pool_name: pool,
          pool_size: 1
        )

      start_supervised!({GrpcConnectionPool, config})
      :ok = GrpcConnectionPool.await_ready(pool, 5_000)
      test_pid = self()

      assert {:ok, :sent} =
               Request.execute(
                 fn _channel, opts ->
                   send(test_pid, {:grpc_opts, opts})
                   :sent
                 end,
                 pool: pool
               )

      assert_received {:grpc_opts, opts}
      refute Keyword.has_key?(opts, :metadata)

      # Through the public API as well (the emulator accepts unauthenticated calls).
      topic = "auth-plaintext-#{System.unique_integer([:positive])}"
      on_exit(fn -> PubsubGrpc.delete_topic("test-project-id", topic) end)
      assert {:ok, _} = PubsubGrpc.create_topic("test-project-id", topic, pool: pool)

      refute_received :token_fetched
    end
  end

  describe ":auth_timeout at read time" do
    test "an invalid runtime value falls back to the default" do
      for value <- [0, -500, :infinity, "5000"] do
        Application.put_env(:pubsub_grpc, :auth_timeout, value)
        assert Config.auth_timeout() == 10_000
      end

      Application.put_env(:pubsub_grpc, :auth_timeout, 1_234)
      assert Config.auth_timeout() == 1_234
    end
  end

  describe "gcloud CLI fallback" do
    test "uses the last output line when it is token-shaped" do
      fake_gcloud("""
      echo "WARNING: Python 3.9 is deprecated" >&2
      echo "ya29.a0AfB_byC-valid_token~+/=="
      """)

      assert {:ok, "Bearer ya29.a0AfB_byC-valid_token~+/=="} = Auth.get_token()
    end

    test "a short status line after the token (\"Done.\") is not taken for the token" do
      fake_gcloud("""
      echo "ya29.a0AfB_byC-valid_token~+/=="
      echo "Done." >&2
      """)

      assert {:ok, "Bearer ya29.a0AfB_byC-valid_token~+/=="} = Auth.get_token()
    end

    test "output with only short token-shaped words is rejected" do
      fake_gcloud("""
      echo "Done."
      """)

      capture_log(fn ->
        assert {:error, %Error{code: :unauthenticated}} = Auth.get_token()
      end)

      assert :miss = Cache.lookup()
    end

    test "rejects output that is not a token and does not cache it" do
      fake_gcloud("""
      echo "ERROR: (gcloud.auth) Your default credentials were not found"
      """)

      log =
        capture_log(fn ->
          assert {:error, %Error{code: :unauthenticated, message: message}} = Auth.get_token()
          assert message =~ "not an access token"
        end)

      refute log =~ "credentials were not found"
      assert :miss = Cache.lookup()
    end

    test "failure logs do not include raw output or token-shaped content" do
      fake_gcloud("""
      echo "Bearer ya29.SECRET_DO_NOT_LEAK_ME_1234567890" >&2
      exit 1
      """)

      log =
        capture_log(fn ->
          assert {:error, %Error{code: :unauthenticated}} = Auth.get_token()
        end)

      assert log =~ "gcloud CLI auth failed (exit 1)"
      refute log =~ ~r/Bearer\s+[A-Za-z0-9\.\-_]{20,}/
      refute log =~ ~r/ya29\.[A-Za-z0-9\.\-_]{10,}/
    end

    test "returns :unauthenticated when gcloud is not on PATH" do
      empty_dir = tmp_dir()
      put_path(empty_dir)

      capture_log(fn ->
        assert {:error, %Error{code: :unauthenticated, message: "gcloud not found"}} =
                 Auth.get_token()
      end)
    end

    test "a hung gcloud is killed by the CLI's own deadline, before the Cache timer" do
      # auth_timeout 750 -> CLI deadline 500 ms; the Cache backstop fires at 750.
      dir = tmp_dir()
      pid_file = Path.join(dir, "gcloud.pid")
      fake_gcloud("echo $$ > #{pid_file}\nexec sleep #{unique_sleep_arg()}\n")
      Application.put_env(:pubsub_grpc, :auth_timeout, 750)

      log =
        capture_log(fn ->
          assert {:error, %Error{code: :deadline_exceeded}} = Auth.get_token()
        end)

      # Only the in-task CLI deadline path logs this; the Cache timer terminates the
      # task without it.
      assert log =~ "gcloud CLI auth timed out"

      # `exec` keeps the shell's PID, so this is the sleep process.
      os_pid = pid_file |> File.read!() |> String.trim()
      eventually(fn -> not os_pid_alive?(os_pid) end)
      assert :miss = Cache.lookup()
    end
  end

  describe "CLI.run/3" do
    test "returns {:error, :timeout} and kills the OS process at its deadline" do
      marker = unique_sleep_arg()

      assert {:error, :timeout} = CLI.run(System.find_executable("sleep"), [marker], 100)
      eventually(fn -> not os_process_running?("sleep #{marker}") end)
    end

    test "kills the OS process when its task is terminated" do
      marker = unique_sleep_arg()
      sleep = System.find_executable("sleep")

      task =
        Task.Supervisor.async_nolink(PubsubGrpc.TaskSupervisor, fn ->
          CLI.run(sleep, [marker], 60_000)
        end)

      eventually(fn -> os_process_running?("sleep #{marker}") end)
      :ok = Task.Supervisor.terminate_child(PubsubGrpc.TaskSupervisor, task.pid)
      eventually(fn -> not os_process_running?("sleep #{marker}") end)
    end
  end

  describe "Goth fallback policy" do
    test "does not fall back to gcloud when Goth is configured" do
      # Point at a name that has no registered Goth process. get_token/0 must
      # surface a Goth-flavored error, not silently try the gcloud CLI.
      Application.put_env(:pubsub_grpc, :goth, PubsubGrpc.Test.NonExistentGoth)

      log =
        capture_log(fn ->
          assert {:error, %Error{code: :unauthenticated, message: message}} = Auth.get_token()
          refute message =~ "gcloud"
        end)

      refute log =~ "gcloud CLI auth failed"
    end
  end

  describe "Goth token source" do
    setup do
      {:ok, _} = Application.ensure_all_started(:goth)
      :ok
    end

    test "returns \"<type> <token>\" and caches it until expiry minus 60 s" do
      start_goth(200, ~s({"access_token":"ya29.goth","expires_in":3600,"token_type":"Bearer"}))

      assert {:ok, "Bearer ya29.goth"} = Auth.get_token()

      assert [{:token, "Bearer ya29.goth", expires_at}] = :ets.lookup(Cache.table(), :token)
      ttl_ms = expires_at - System.monotonic_time(:millisecond)
      # 3600 s - 60 s skew; Goth's expiry has second resolution.
      assert ttl_ms in 3_538_000..3_540_000

      assert {:ok, "Bearer ya29.goth"} = Cache.lookup()
    end

    test "a token expiring within the 60 s skew is returned but not cached" do
      start_goth(200, ~s({"access_token":"ya29.short","expires_in":30,"token_type":"Bearer"}))

      assert {:ok, "Bearer ya29.short"} = Auth.get_token()
      assert :miss = Cache.lookup()
    end

    test "a Goth error is :unauthenticated and does not leak the response body" do
      start_goth(500, ~s({"error":"secret-response-body"}))

      log =
        capture_log(fn ->
          assert {:error,
                  %Error{
                    code: :unauthenticated,
                    message: "Goth authentication failed",
                    details: RuntimeError
                  } = error} = Auth.get_token()

          refute inspect(error, structs: false) =~ "secret-response-body"
        end)

      assert log =~ "Goth.fetch failed"
      refute log =~ "secret-response-body"
      assert :miss = Cache.lookup()
    end
  end

  # Starts a real Goth whose HTTP client always answers `status`/`body`, and
  # points :pubsub_grpc at it.
  defp start_goth(status, body) do
    name = :"pubsub_grpc_test_goth_#{System.unique_integer([:positive])}"

    http_client = fn _request -> {:ok, %{status: status, headers: [], body: body}} end

    start_supervised!({
      Goth,
      # A failed fetch must not be retried during the test.
      name: name,
      source: {:metadata, []},
      http_client: http_client,
      prefetch: :sync,
      retry_delay: fn _ -> :timer.hours(1) end
    })

    Application.put_env(:pubsub_grpc, :goth, name)
  end

  @doc false
  def handle_auth_event(_event, _measurements, metadata, test_pid) do
    send(test_pid, {:auth_stop, metadata})
  end

  defp put_fetcher(fun), do: Application.put_env(:pubsub_grpc, :token_fetcher, fun)

  defp restore_config_on_exit(_context) do
    original = Config.resolve(Application.get_all_env(:pubsub_grpc))
    emulator = Application.get_env(:pubsub_grpc, :emulator)

    on_exit(fn ->
      Config.put(original)
      Application.put_env(:pubsub_grpc, :emulator, emulator)
    end)
  end

  # Reports its pid to the test, then blocks until it receives :release.
  defp blocking_fetcher(counter, result) do
    test_pid = self()

    fn ->
      :counters.add(counter, 1, 1)
      send(test_pid, {:fetch_started, self()})

      receive do
        :release -> result
      end
    end
  end

  defp waiter_count do
    case :sys.get_state(Cache) do
      %{inflight: %{waiters: waiters}} -> length(waiters)
      _ -> 0
    end
  end

  defp attach_auth_stop_handler do
    handler_id = "auth-test-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:pubsub_grpc, :auth, :stop],
      &__MODULE__.handle_auth_event/4,
      self()
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  defp fake_gcloud(body) do
    dir = tmp_dir()
    path = Path.join(dir, "gcloud")
    File.write!(path, "#!/bin/sh\n" <> body)
    File.chmod!(path, 0o755)
    put_path(dir <> ":" <> System.get_env("PATH", ""))
  end

  defp put_path(path) do
    original = System.get_env("PATH")
    System.put_env("PATH", path)
    on_exit(fn -> System.put_env("PATH", original) end)
  end

  defp tmp_dir do
    dir = Path.join(System.tmp_dir!(), "pubsub_grpc_auth_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  defp unique_sleep_arg, do: "#{900_000 + System.unique_integer([:positive])}"

  defp os_process_running?(command) do
    {output, 0} = System.cmd("ps", ["-ax", "-o", "command="])
    output |> String.split("\n") |> Enum.any?(&String.contains?(&1, command))
  end

  defp os_pid_alive?(os_pid) do
    {_output, status} = System.cmd("ps", ["-p", os_pid], stderr_to_stdout: true)
    status == 0
  end
end
