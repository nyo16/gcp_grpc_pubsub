defmodule PubsubGrpc.AuthTest do
  # Sync: mutates global state (app env, persistent_term Config, the OS PATH,
  # Goth.Registry entries) and kills/restarts the named Auth.Cache process.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import PubsubGrpc.Eventually, only: [eventually: 1]

  alias PubsubGrpc.{Auth, Config, Error, Request}
  alias PubsubGrpc.Auth.{Cache, CLI}

  @env_keys [:token_fetcher, :goth, :auth_timeout]
  # Cross-process events (caller -> Cache -> fetch task) took up to 184 ms under CPU starvation.
  @cross_process_timeout 5_000

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

  describe "global endpoint type" do
    setup :restore_config_on_exit

    test "the :emulator shorthand is a local endpoint" do
      assert Application.get_env(:pubsub_grpc, :emulator) != nil
      assert Config.emulator?()
    end

    test "a type: :local endpoint is local without any :emulator key" do
      Application.delete_env(:pubsub_grpc, :emulator)

      Config.put(
        Config.resolve([
          {GrpcConnectionPool, [endpoint: [type: :local, host: "localhost", port: 8085]]}
        ])
      )

      assert Config.emulator?()
    end

    test "a production endpoint is not local even if :emulator is set" do
      assert Application.get_env(:pubsub_grpc, :emulator) != nil
      Config.put(Config.resolve([]))

      refute Config.emulator?()
    end

    test "Config readers fall back to the application env when nothing is stored" do
      :persistent_term.erase({Config, :resolved})

      assert Config.pool_name() == PubsubGrpc.ConnectionPool
      assert Config.emulator?()
    end

    # Security fail-safe: an unresolvable config must never be taken for the
    # emulator, so authentication is never skipped.
    test "an unresolvable config is treated as production, with the default pool" do
      on_exit(fn -> Application.delete_env(:pubsub_grpc, GrpcConnectionPool) end)
      Application.put_env(:pubsub_grpc, GrpcConnectionPool, :not_a_keyword)
      :persistent_term.erase({Config, :resolved})
      put_fetcher(fn -> {:ok, "Bearer failsafe", 60_000} end)

      assert Config.endpoint_type() == :production
      refute Config.emulator?()
      assert Config.pool_name() == PubsubGrpc.ConnectionPool
      assert Config.default_timeout() == 30_000

      tls_channel = %GRPC.Channel{scheme: "https", cred: %GRPC.Credential{ssl: []}}
      metadata = [metadata: %{"authorization" => "Bearer failsafe"}]
      assert {:ok, ^metadata} = Auth.request_opts(tls_channel)
      assert {:ok, ^metadata} = deprecated_request_opts()
    end
  end

  describe "request_opts/0 (deprecated)" do
    setup :restore_config_on_exit

    test "still decides from the global endpoint type" do
      test_pid = self()

      put_fetcher(fn ->
        send(test_pid, :token_fetched)
        {:ok, "Bearer t", 60_000}
      end)

      assert {:ok, []} = deprecated_request_opts()
      refute_received :token_fetched

      Config.put(Config.resolve([]))
      assert {:ok, [metadata: %{"authorization" => "Bearer t"}]} = deprecated_request_opts()
      assert_received :token_fetched
    end
  end

  # A direct call to the deprecated function is a compile-time warning, which
  # fails `mix test --warnings-as-errors`.
  # credo:disable-for-next-line Credo.Check.Refactor.Apply
  defp deprecated_request_opts, do: apply(Auth, :request_opts, [])

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
      assert {:ok, "Bearer cached", :fresh} = Cache.lookup()

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

    test "a fetch error is served from the negative cache during its backoff" do
      counter = :counters.new(1, [])

      put_fetcher(fn ->
        :counters.add(counter, 1, 1)
        {:error, Error.new(:unauthenticated, "nope")}
      end)

      assert {:error, %Error{code: :unauthenticated, message: "nope"}} = Auth.get_token()
      # Independent of how long the call above took: the window ends in a minute.
      extend_backoff()
      assert {:error, %Error{code: :unauthenticated, message: "nope"}} = Auth.get_token()
      assert :counters.get(counter, 1) == 1
      assert :miss = Cache.lookup()
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
      assert_receive {:fetch_started, fetch_pid}, @cross_process_timeout
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

      for result <- Task.await_many(callers) do
        assert {:error, %Error{code: :deadline_exceeded}} = result
      end

      # The timed-out fetch task is terminated after the waiters got their reply. Under CPU
      # starvation the 100 ms timer can fire before the task even runs, so its start is not
      # awaited; the task is gone either way.
      eventually(fn -> Task.Supervisor.children(PubsubGrpc.TaskSupervisor) == [] end)
    end

    test "callers get an error, not an exit, when Auth.Cache dies mid-flight" do
      put_fetcher(blocking_fetcher(:counters.new(1, []), :never_released))
      old_cache = Process.whereis(Cache)

      caller = Task.async(&Auth.get_token/0)
      assert_receive {:fetch_started, fetch_pid}, @cross_process_timeout
      eventually(fn -> waiter_count() == 1 end)

      Process.exit(old_cache, :kill)

      assert {:error, %Error{code: :unauthenticated}} = Task.await(caller)

      Process.exit(fetch_pid, :kill)

      new_cache =
        eventually(fn ->
          pid = Process.whereis(Cache)
          pid not in [nil, old_cache] && pid
        end)

      # The name is registered before init/1 creates the table; wait for init to finish.
      _ = :sys.get_state(new_cache)
      assert :ets.info(Cache.table(), :owner) == new_cache
    end

    test "a fetch task killed from outside releases every waiter at once" do
      # Far beyond the assertion below: the waiters must not wait for the timer.
      Application.put_env(:pubsub_grpc, :auth_timeout, 10_000)
      counter = :counters.new(1, [])
      put_fetcher(blocking_fetcher(counter, :never_released))

      callers = for _ <- 1..5, do: Task.async(&Auth.get_token/0)
      assert_receive {:fetch_started, fetch_pid}, @cross_process_timeout
      eventually(fn -> waiter_count() == 5 end)

      Process.exit(fetch_pid, :kill)
      results = Task.await_many(callers, 5_000)

      for result <- results do
        assert {:error, %Error{code: :unauthenticated, message: "auth token fetch crashed"}} =
                 result
      end

      assert %{inflight: nil} = :sys.get_state(Cache)

      # The crash is negatively cached; clear_cache/0 drops the backoff, and the next
      # miss starts a new fetch.
      Auth.clear_cache()
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
      assert {:ok, "Bearer cached", :fresh} = Cache.lookup()
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

      assert {:ok, "Bearer shared", :fresh} = Cache.lookup()

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
      assert {:ok, "Bearer new", :fresh} = Cache.lookup()

      assert :ok = Auth.invalidate("Bearer new")
      assert :miss = Cache.lookup()
    end

    test "status 16 on a plaintext channel (no token sent) leaves the cache alone" do
      put_fetcher(fn -> {:ok, "Bearer cached", 60_000} end)
      assert {:ok, "Bearer cached"} = Auth.get_token()
      plaintext = %GRPC.Channel{scheme: "http", cred: nil}

      assert @unauthenticated = Request.call(plaintext, fn _ch, _opts -> @unauthenticated end, [])
      assert {:ok, "Bearer cached", :fresh} = Cache.lookup()
    end
  end

  describe "clear during an in-flight fetch" do
    test "the fetch answers its waiters but its token is not cached" do
      put_fetcher(blocking_fetcher(:counters.new(1, []), {:ok, "Bearer stale", 60_000}))

      caller = Task.async(&Auth.get_token/0)
      assert_receive {:fetch_started, fetch_pid}, @cross_process_timeout
      eventually(fn -> waiter_count() == 1 end)

      assert :ok = Auth.clear_cache()
      send(fetch_pid, :release)

      assert {:ok, "Bearer stale"} = Task.await(caller)
      assert :miss = Cache.lookup()

      # A fetch started after the clear is cached again.
      put_fetcher(fn -> {:ok, "Bearer fresh", 60_000} end)
      assert {:ok, "Bearer fresh"} = Auth.get_token()
      assert {:ok, "Bearer fresh", :fresh} = Cache.lookup()
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
      assert_receive {:fetch_started, 1, first_fetch}, @cross_process_timeout
      eventually(fn -> waiter_count() == 1 end)

      assert :ok = Auth.clear_cache()

      after_clear = Task.async(&Auth.get_token/0)
      assert_receive {:fetch_started, 2, second_fetch}, @cross_process_timeout

      send(second_fetch, :release)
      assert {:ok, "Bearer 2"} = Task.await(after_clear)

      # The pre-clear fetch still answers its own caller, without being cached.
      send(first_fetch, :release)
      assert {:ok, "Bearer 1"} = Task.await(before_clear)

      assert :counters.get(counter, 1) == 2
      assert {:ok, "Bearer 2", :fresh} = Cache.lookup()
      assert %{inflight: nil, stale: stale} = :sys.get_state(Cache)
      assert stale == %{}
    end
  end

  describe "per-call timeout reaching the gRPC call options" do
    setup :restore_config_on_exit

    @plaintext %GRPC.Channel{scheme: "http", cred: nil}

    test ":timeout, then the configured :default_timeout (also for timeout: nil)" do
      grpc_timeout = fn opts ->
        Request.call(@plaintext, fn _ch, grpc -> grpc[:timeout] end, opts)
      end

      assert grpc_timeout.(timeout: 1_234) == 1_234
      assert grpc_timeout.(timeout: :infinity) == :infinity
      assert grpc_timeout.([]) == 30_000
      assert grpc_timeout.(timeout: nil) == 30_000

      env = Keyword.put(Application.get_all_env(:pubsub_grpc), :default_timeout, 7_000)
      Config.put(Config.resolve(env))
      assert grpc_timeout.([]) == 7_000
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
      topic = PubsubGrpc.EmulatorHelper.unique_name("auth-plaintext")
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

    test "a hung gcloud gives :deadline_exceeded and its OS process is killed" do
      # auth_timeout 750 -> CLI deadline 500 ms; the Cache backstop fires at 750. Which one
      # wins depends on scheduling, so only what both guarantee is asserted. The CLI's own
      # deadline is covered deterministically in the CLI.run/3 tests below.
      marker = unique_sleep_arg()
      fake_gcloud("exec sleep #{marker}\n")
      Application.put_env(:pubsub_grpc, :auth_timeout, 750)

      capture_log(fn ->
        assert {:error, %Error{code: :deadline_exceeded}} = Auth.get_token()
      end)

      # Both paths kill the OS process before the fetch task exits.
      eventually(fn -> Task.Supervisor.children(PubsubGrpc.TaskSupervisor) == [] end)
      eventually(fn -> not os_process_running?("sleep #{marker}") end)
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

    test "returns the output of a command that exits before its OS pid is read" do
      # A command this short often exits, and its port closes, before Port.info/2
      # runs (seen on Linux); that must not crash the run. Repeated because it is a race.
      sh = System.find_executable("sh")

      for _ <- 1..100 do
        assert {:ok, "out\n", 3} = CLI.run(sh, ["-c", "echo out; exit 3"], 5_000)
      end
    end

    test "os_pid/1 is nil once the command has exited and its port closed" do
      port = Port.open({:spawn_executable, System.find_executable("true")}, [:exit_status])
      assert_receive {^port, {:exit_status, 0}}
      eventually(fn -> Port.info(port) == nil end)

      assert CLI.os_pid(port) == nil
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

      # 3600 s - 60 s skew; Goth's expiry has second resolution.
      assert cached_ttl_ms() in 3_538_000..3_540_000
      assert {:ok, "Bearer ya29.goth", :fresh} = Cache.lookup()
    end

    test "a token expiring within the 60 s skew is cached for 1 s, not until its expiry" do
      start_goth(200, ~s({"access_token":"ya29.short","expires_in":30,"token_type":"Bearer"}))

      assert {:ok, "Bearer ya29.short"} = Auth.get_token()
      # The 1 s floor, minus the time since the fetch (without it, the TTL would be 0).
      assert cached_ttl_ms() in 900..1_000
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

  describe "Auth.Cache safety nets" do
    test "refresh/2 returns :deadline_exceeded instead of exiting when the Cache is wedged" do
      :sys.suspend(Cache)
      on_exit(fn -> :sys.resume(Cache) end)

      assert {:error, %Error{code: :deadline_exceeded}} =
               Cache.refresh(fn -> {:error, Error.new(:unauthenticated, "unused")} end, 1)

      :sys.resume(Cache)
    end

    # A caller that missed the ETS read can reach the Cache after another fetch
    # stored a token: it must get that token, not start a second fetch.
    test "refresh/2 returns a token cached meanwhile without fetching" do
      put_fetcher(fn -> {:ok, "Bearer cached", 60_000} end)
      assert {:ok, "Bearer cached"} = Auth.get_token()

      assert {:ok, "Bearer cached"} = Cache.refresh(fn -> flunk("fetched") end, 1_000)
    end

    test "late results, :DOWN and timeouts of unknown fetches are ignored" do
      ref = make_ref()
      send(Cache, {ref, {:ok, "Bearer late", 60_000}})
      send(Cache, {:DOWN, ref, :process, self(), :normal})
      send(Cache, {:refresh_timeout, ref})

      # Processed in order: the state read is a barrier.
      assert %{inflight: nil} = :sys.get_state(Cache)
      assert :miss = Cache.lookup()
    end

    test "clear/0, invalidate/1 and lookup/0 are no-ops while the Cache is down" do
      :ok = Supervisor.terminate_child(PubsubGrpc.Supervisor, Cache)
      on_exit(fn -> Supervisor.restart_child(PubsubGrpc.Supervisor, Cache) end)

      assert :ok = Cache.clear()
      assert :ok = Cache.invalidate("Bearer x")
      assert :miss = Cache.lookup()

      assert {:ok, _pid} = Supervisor.restart_child(PubsubGrpc.Supervisor, Cache)
    end
  end

  describe "auth error paths" do
    test "a fetcher that throws or exits is an :unauthenticated error tagged with the kind" do
      for {fetcher, kind} <- [{fn -> throw(:boom) end, :throw}, {fn -> exit(:boom) end, :exit}] do
        put_fetcher(fetcher)
        Auth.clear_cache()

        assert {:error,
                %Error{
                  code: :unauthenticated,
                  message: "auth token fetch crashed",
                  details: ^kind
                }} =
                 Auth.get_token()
      end
    end

    test "Goth raising is :unauthenticated and logs neither the token nor the arguments" do
      # A token without a type does not match handle_goth_result/1: FunctionClauseError,
      # whose message would embed the token.
      fake_goth(%Goth.Token{token: "ya29.untyped-secret", type: nil, expires: :never}, nil)

      log =
        capture_log(fn ->
          assert {:error,
                  %Error{
                    code: :unauthenticated,
                    message: "Goth authentication crashed",
                    details: FunctionClauseError
                  } = error} = Auth.get_token()

          refute inspect(error, structs: false) =~ "untyped-secret"
        end)

      assert log =~ "Goth.fetch raised: FunctionClauseError"
      refute log =~ "untyped-secret"
    end

    test "Goth errors are tagged by shape, never by content" do
      expired = %Goth.Token{token: "ya29.old", type: "Bearer", expires: 0}

      for {reason, tag} <- [
            {:nxdomain, :nxdomain},
            {{:http_error, "secret-body"}, :http_error},
            {"secret-string", :unknown}
          ] do
        Auth.clear_cache()
        fake_goth(expired, {:error, reason})

        log =
          capture_log(fn ->
            assert {:error, %Error{code: :unauthenticated, details: ^tag}} = Auth.get_token()
          end)

        assert log =~ "Goth.fetch failed (#{inspect(tag)})"
        refute log =~ "secret"
      end
    end

    test "a Goth expiry that is a DateTime is honoured; nil or another value means 50 min" do
      in_an_hour = DateTime.add(DateTime.utc_now(), 3_600)

      for {expires, expected_ttl} <- [
            {in_an_hour, 3_540_000},
            {nil, 3_000_000},
            {"tomorrow", 3_000_000}
          ] do
        Auth.clear_cache()
        fake_goth(%Goth.Token{token: "ya29.t", type: "Bearer", expires: expires}, nil)

        assert {:ok, "Bearer ya29.t"} = Auth.get_token()
        assert_in_delta cached_ttl_ms(), expected_ttl, 2_000
      end
    end
  end

  describe "refresh-ahead" do
    # First fetch: "Bearer t1" at once. Later fetches block (see blocking_fetcher/2),
    # then return `later`.
    defp first_then_blocking(counter, later) do
      blocking = blocking_fetcher(counter, later)

      fn ->
        if :counters.get(counter, 1) == 0 do
          :counters.add(counter, 1, 1)
          {:ok, "Bearer t1", 60_000}
        else
          blocking.()
        end
      end
    end

    test "a token is due 5 minutes before expiry, or after 90% of a short lifetime" do
      for {ttl, margin} <- [{3_600_000, 300_000}, {60_000, 6_000}, {1_000, 100}] do
        Auth.clear_cache()
        put_fetcher(fn -> {:ok, "Bearer t", ttl} end)
        assert {:ok, "Bearer t"} = Auth.get_token()

        [{:token, "Bearer t", expires_at, refresh_at}] = :ets.lookup(Cache.table(), :token)
        assert expires_at - refresh_at == margin
      end
    end

    test "a due token is served while exactly one background fetch replaces it" do
      counter = :counters.new(1, [])
      put_fetcher(first_then_blocking(counter, {:ok, "Bearer t2", 60_000}))
      attach_auth_stop_handler()

      assert {:ok, "Bearer t1"} = Auth.get_token()
      assert_receive {:auth_stop, %{result: :ok}}
      make_refresh_due()

      # Nobody waits for the background fetch.
      callers = for _ <- 1..50, do: Task.async(&Auth.get_token/0)
      assert Enum.all?(Task.await_many(callers), &(&1 == {:ok, "Bearer t1"}))

      assert_receive {:fetch_started, fetch_pid}, @cross_process_timeout
      assert %{inflight: %{waiters: []}} = :sys.get_state(Cache)
      send(fetch_pid, :release)

      eventually(fn -> Cache.lookup() == {:ok, "Bearer t2", :fresh} end)
      assert :counters.get(counter, 1) == 2
      assert_receive {:auth_stop, %{result: :ok}}
      refute_receive {:auth_stop, _}, 50
    end

    test "callers that miss while a refresh-ahead runs join it" do
      counter = :counters.new(1, [])
      put_fetcher(first_then_blocking(counter, {:ok, "Bearer t2", 60_000}))

      assert {:ok, "Bearer t1"} = Auth.get_token()
      make_refresh_due()
      assert {:ok, "Bearer t1"} = Auth.get_token()
      assert_receive {:fetch_started, fetch_pid}, @cross_process_timeout

      # The token expires before the background fetch returns.
      expire_cached_token()
      caller = Task.async(&Auth.get_token/0)
      eventually(fn -> waiter_count() == 1 end)
      send(fetch_pid, :release)

      assert {:ok, "Bearer t2"} = Task.await(caller)
      assert :counters.get(counter, 1) == 2
    end

    test "a failed refresh-ahead keeps serving the token and backs off before retrying" do
      counter = :counters.new(1, [])
      error = {:error, Error.new(:unavailable, "metadata server down")}
      put_fetcher(first_then_blocking(counter, error))

      assert {:ok, "Bearer t1"} = Auth.get_token()
      make_refresh_due()
      assert {:ok, "Bearer t1"} = Auth.get_token()
      assert_receive {:fetch_started, fetch_pid}, @cross_process_timeout
      send(fetch_pid, :release)
      eventually(fn -> match?(%{inflight: nil, failure: %{}}, :sys.get_state(Cache)) end)

      # Inside the backoff: still served, not due, no new fetch. The window is pushed
      # a minute ahead so the assertions do not depend on the real 1 s backoff.
      extend_backoff()
      update_cached_row(4, now_ms() + 60_000)
      for _ <- 1..10, do: assert({:ok, "Bearer t1"} = Auth.get_token())
      assert {:ok, "Bearer t1", :fresh} = Cache.lookup()
      assert :counters.get(counter, 1) == 2

      # Once the backoff has passed, the token is due again and refreshed ahead.
      expire_backoff()
      make_refresh_due()
      assert {:ok, "Bearer t1"} = Auth.get_token()
      assert_receive {:fetch_started, fetch_pid}, @cross_process_timeout
      send(fetch_pid, :release)
      eventually(fn -> match?(%{inflight: nil}, :sys.get_state(Cache)) end)
    end
  end

  describe "negative cache" do
    test "the backoff starts at 1 s, doubles per consecutive failure up to 5 s, resets on success" do
      counter = :counters.new(1, [])

      put_fetcher(fn ->
        :counters.add(counter, 1, 1)
        {:error, Error.new(:unauthenticated, "nope")}
      end)

      backoffs =
        for _ <- 1..5 do
          assert {:error, %Error{message: "nope"}} = Auth.get_token()
          %{failure: %{backoff: backoff}} = :sys.get_state(Cache)
          expire_backoff()
          backoff
        end

      assert backoffs == [1_000, 2_000, 4_000, 5_000, 5_000]
      assert :counters.get(counter, 1) == 5

      put_fetcher(fn -> {:ok, "Bearer ok", 60_000} end)
      assert {:ok, "Bearer ok"} = Auth.get_token()
      assert %{failure: nil} = :sys.get_state(Cache)
    end

    test "clear_cache/0 drops the backoff" do
      counter = :counters.new(1, [])

      put_fetcher(fn ->
        :counters.add(counter, 1, 1)
        {:error, Error.new(:unauthenticated, "nope")}
      end)

      assert {:error, _} = Auth.get_token()
      assert :ok = Auth.clear_cache()
      assert {:error, _} = Auth.get_token()
      assert :counters.get(counter, 1) == 2
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

  # Rewrites element `pos` of the cached row from inside Auth.Cache, the only
  # process allowed to write its :protected table: 3 is the expiry, 4 the time
  # from which the token is due for a refresh-ahead (monotonic ms).
  defp update_cached_row(pos, value) do
    :sys.replace_state(Cache, fn state ->
      true = :ets.update_element(Cache.table(), :token, {pos, value})
      state
    end)
  end

  # Monotonic time can be negative: "now" is the only safe past instant.
  defp now_ms, do: System.monotonic_time(:millisecond)

  defp make_refresh_due, do: update_cached_row(4, now_ms())
  defp expire_cached_token, do: update_cached_row(3, now_ms())

  # Ends the current failure backoff without waiting for it.
  defp expire_backoff do
    until = now_ms()

    :sys.replace_state(Cache, fn %{failure: failure} = state ->
      %{state | failure: %{failure | until: until}}
    end)
  end

  # Pushes the current failure backoff a minute ahead.
  defp extend_backoff do
    until = now_ms() + 60_000

    :sys.replace_state(Cache, fn %{failure: failure} = state ->
      %{state | failure: %{failure | until: until}}
    end)
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

  # Registers a fake Goth under a unique name and points :pubsub_grpc at it.
  # `Goth.fetch/1` reads `token` straight from the registry unless it has an
  # integer `expires` in the past; then it calls the process, which answers
  # `fetch_reply`.
  defp fake_goth(token, fetch_reply) do
    name = :"pubsub_grpc_fake_goth_#{System.unique_integer([:positive])}"
    test_pid = self()

    pid =
      spawn_link(fn ->
        {:ok, _} = Registry.register(Goth.Registry, name, token)
        send(test_pid, {:fake_goth_registered, self()})
        fake_goth_loop(fetch_reply)
      end)

    assert_receive {:fake_goth_registered, ^pid}
    on_exit(fn -> Process.exit(pid, :kill) end)
    Application.put_env(:pubsub_grpc, :goth, name)
  end

  defp fake_goth_loop(fetch_reply) do
    receive do
      {:"$gen_call", from, :fetch} ->
        GenServer.reply(from, fetch_reply)
        fake_goth_loop(fetch_reply)
    end
  end

  # The row's third element is the expiry (monotonic ms), whatever follows it.
  defp cached_ttl_ms do
    [row] = :ets.lookup(Cache.table(), :token)
    elem(row, 2) - System.monotonic_time(:millisecond)
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
end
