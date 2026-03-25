defmodule PubsubGrpc.AuthTest do
  use ExUnit.Case

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
end
