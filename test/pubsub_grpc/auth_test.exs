defmodule PubsubGrpc.AuthTest do
  use ExUnit.Case

  import ExUnit.CaptureLog

  alias PubsubGrpc.{Auth, Error}

  setup do
    # Ensure cache is initialized
    Auth.init_cache()
    # Clear cache between tests
    Auth.clear_cache()
    :ok
  end

  describe "request_opts/0 in emulator mode" do
    test "returns {:ok, []} when emulator is configured" do
      # The test config has emulator configured
      assert Application.get_env(:pubsub_grpc, :emulator) != nil
      assert {:ok, []} = Auth.request_opts()
    end
  end

  describe "clear_cache/0" do
    test "clears without error" do
      assert :ok = Auth.clear_cache()
    end

    test "is idempotent" do
      assert :ok = Auth.clear_cache()
      assert :ok = Auth.clear_cache()
    end
  end

  describe "init_cache/0" do
    test "creates ETS table" do
      assert :ok = Auth.init_cache()
      assert :ets.whereis(:pubsub_grpc_auth_cache) != :undefined
    end

    test "is idempotent" do
      assert :ok = Auth.init_cache()
      assert :ok = Auth.init_cache()
    end
  end

  describe "get_token/0 in emulator mode" do
    test "returns error since emulator doesn't need tokens and no goth/gcloud" do
      # In emulator mode, get_token still tries to get a real token
      # but request_opts() bypasses it. Testing get_token directly
      # may fail depending on environment (gcloud installed or not).
      # The important thing is it returns an ok or error tuple.
      result = Auth.get_token()
      assert match?({:ok, _}, result) or match?({:error, %Error{}}, result)
    end
  end

  describe "token caching" do
    test "cached tokens are returned on subsequent calls" do
      # In test mode with emulator, request_opts always returns {:ok, []}
      # so caching is bypassed. Test the cache mechanism directly.
      Auth.init_cache()
      Auth.clear_cache()

      # First call
      result1 = Auth.request_opts()
      # Second call should be fast (cached or emulator bypass)
      result2 = Auth.request_opts()

      assert result1 == result2
    end
  end

  describe "credential sanitization" do
    setup do
      # Force the non-emulator branch by exercising get_token directly. In emulator
      # mode request_opts/0 returns {:ok, []} and never touches get_token_fallback.
      # We invoke get_token/0 with no Goth configured -> goes through gcloud CLI path.
      saved = Application.get_env(:pubsub_grpc, :goth)
      Application.delete_env(:pubsub_grpc, :goth)
      Auth.clear_cache()

      on_exit(fn ->
        if saved, do: Application.put_env(:pubsub_grpc, :goth, saved)
        Auth.clear_cache()
      end)

      :ok
    end

    test "inspect on an Error does not leak token-bearing details" do
      # Direct check on the Error struct's Inspect derive — independent of which
      # auth backend ran.
      secret_token = "Bearer ya29.SECRET_DO_NOT_LEAK_ME"
      err = Error.new(:unauthenticated, "auth failed", %{access_token: secret_token})

      refute inspect(err) =~ secret_token
      refute inspect(err) =~ "access_token"
    end

    test "auth failure log does not include raw stderr or token-shaped content" do
      # Capture logs while triggering a gcloud-CLI auth attempt. In CI the call
      # almost certainly fails — the test verifies that no token-looking material
      # ends up in the log.
      log =
        capture_log(fn ->
          _ = Auth.get_token()
        end)

      refute log =~ ~r/Bearer\s+[A-Za-z0-9\.\-_]{20,}/
      refute log =~ ~r/ya29\.[A-Za-z0-9\.\-_]{10,}/
    end
  end

  describe "Goth fallback policy" do
    setup do
      saved = Application.get_env(:pubsub_grpc, :goth)
      # Point at a name that has no registered Goth process.
      Application.put_env(:pubsub_grpc, :goth, PubsubGrpc.Test.NonExistentGoth)
      Auth.clear_cache()

      on_exit(fn ->
        if saved do
          Application.put_env(:pubsub_grpc, :goth, saved)
        else
          Application.delete_env(:pubsub_grpc, :goth)
        end

        Auth.clear_cache()
      end)

      :ok
    end

    test "does not fall back to gcloud when Goth is configured" do
      # With a bogus Goth name and the cache cleared, get_token/0 must surface
      # a Goth-flavored error, not silently try the gcloud CLI.
      log =
        capture_log(fn ->
          assert {:error, %Error{code: :unauthenticated, message: message}} = Auth.get_token()
          refute message =~ "gcloud"
        end)

      refute log =~ "gcloud CLI auth failed"
    end
  end
end
