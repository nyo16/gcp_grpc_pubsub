defmodule PubsubGrpc.RequestOptionsTest do
  use ExUnit.Case, async: true

  # Pools pointed at a closed port log every failed connection attempt.
  @moduletag :capture_log

  alias PubsubGrpc.{Client, Error}

  @project "my-project"
  @opts [timeout: 1_000, pool: :pubsub_grpc_no_such_pool]

  describe "common options reach the pool checkout" do
    # Each operation passes validation, then fails to check out a connection from
    # the nonexistent pool. The emulator config means no auth token is needed.
    test "every operation accepts :timeout and :pool" do
      calls = [
        {:create_topic, fn -> PubsubGrpc.create_topic(@project, "topic", @opts) end},
        {:get_topic, fn -> PubsubGrpc.get_topic(@project, "topic", @opts) end},
        {:delete_topic, fn -> PubsubGrpc.delete_topic(@project, "topic", @opts) end},
        {:list_topics, fn -> PubsubGrpc.list_topics(@project, @opts) end},
        {:publish, fn -> PubsubGrpc.publish(@project, "topic", [%{data: "x"}], @opts) end},
        {:publish_message_5,
         fn -> PubsubGrpc.publish_message(@project, "topic", "x", %{"k" => "v"}, @opts) end},
        {:publish_message_4_opts,
         fn -> PubsubGrpc.publish_message(@project, "topic", "x", @opts) end},
        {:create_subscription,
         fn -> PubsubGrpc.create_subscription(@project, "topic", "sub", @opts) end},
        {:get_subscription, fn -> PubsubGrpc.get_subscription(@project, "sub", @opts) end},
        {:delete_subscription, fn -> PubsubGrpc.delete_subscription(@project, "sub", @opts) end},
        {:list_subscriptions, fn -> PubsubGrpc.list_subscriptions(@project, @opts) end},
        {:pull, fn -> PubsubGrpc.pull(@project, "sub", 10, @opts) end},
        {:acknowledge, fn -> PubsubGrpc.acknowledge(@project, "sub", ["ack"], @opts) end},
        {:modify_ack_deadline,
         fn -> PubsubGrpc.modify_ack_deadline(@project, "sub", ["ack"], 30, @opts) end},
        {:nack, fn -> PubsubGrpc.nack(@project, "sub", ["ack"], @opts) end},
        {:list_schemas, fn -> PubsubGrpc.list_schemas(@project, @opts) end},
        {:get_schema, fn -> PubsubGrpc.get_schema(@project, "schema", @opts) end},
        {:create_schema,
         fn -> PubsubGrpc.create_schema(@project, "schema", :avro, "{}", @opts) end},
        {:delete_schema, fn -> PubsubGrpc.delete_schema(@project, "schema", @opts) end},
        {:validate_schema, fn -> PubsubGrpc.validate_schema(@project, :avro, "{}", @opts) end},
        {:list_schema_revisions,
         fn -> PubsubGrpc.list_schema_revisions(@project, "schema", @opts) end},
        {:validate_message,
         fn -> PubsubGrpc.validate_message(@project, "schema", "{}", :json, @opts) end},
        {:validate_message_with_schema,
         fn ->
           PubsubGrpc.validate_message_with_schema(@project, :avro, "{}", "{}", :json, @opts)
         end}
      ]

      for {name, call} <- calls do
        assert {:error, %Error{code: :connection_error, details: :not_connected}} = call.(),
               "#{name} did not use the :pool option"
      end
    end

    test "existing arities without opts are still callable" do
      Code.ensure_loaded!(PubsubGrpc)
      Code.ensure_loaded!(PubsubGrpc.Schema)

      assert function_exported?(PubsubGrpc, :create_topic, 2)
      assert function_exported?(PubsubGrpc, :publish_message, 3)
      assert function_exported?(PubsubGrpc, :publish_message, 4)
      assert function_exported?(PubsubGrpc, :create_schema, 4)
      assert function_exported?(PubsubGrpc, :validate_message, 4)
      assert function_exported?(PubsubGrpc, :validate_message_with_schema, 5)
      assert function_exported?(PubsubGrpc.Schema, :delete_schema, 2)
    end

    test "publish_message/4 treats only a keyword list of common options as opts" do
      # Common options: routed as opts, so the bogus pool is used.
      assert {:error, %Error{code: :connection_error}} =
               PubsubGrpc.publish_message(@project, "topic", "x", @opts)

      # Any other list is validated as attributes and rejected, never dropped.
      for attributes <- [[source: "app"], [{"k", "v"}], [timeout: 1, source: "app"]] do
        assert {:error, %Error{code: :validation_error}} =
                 PubsubGrpc.publish_message(@project, "topic", "x", attributes)
      end
    end

    test "resource IDs with a trailing newline are rejected" do
      assert {:error, %Error{code: :validation_error}} =
               PubsubGrpc.create_topic(@project, "my-topic\n", @opts)

      assert {:error, %Error{code: :validation_error}} =
               PubsubGrpc.get_subscription(@project, "my-sub\n", @opts)
    end
  end

  describe "Client.execute/2 when no connection is ready" do
    test "waits up to the timeout, then reports :not_connected" do
      pool = start_pool(port: 1)

      {elapsed_us, result} =
        :timer.tc(fn ->
          Client.execute(fn _channel -> :unreachable end, pool: pool, timeout: 300)
        end)

      assert result == {:error, :not_connected}
      assert elapsed_us >= 300_000
      assert elapsed_us < 2_000_000
    end

    test "the wait is capped at 2 seconds regardless of :timeout" do
      pool = start_pool(port: 1)

      {elapsed_us, {:error, :not_connected}} =
        :timer.tc(fn -> Client.execute(fn _ -> :unreachable end, pool: pool, timeout: 60_000) end)

      assert elapsed_us >= 2_000_000
      # Far below the 60 s :timeout; the slack absorbs a loaded full-suite run.
      assert elapsed_us < 6_000_000
    end

    @tag :integration
    test "retries the checkout once the pool connects" do
      pool = start_pool(port: 8085)

      # Connections are established asynchronously after start.
      assert {:error, :not_connected} = GrpcConnectionPool.get_channel(pool)

      assert {:ok, %GRPC.Channel{}} =
               Client.execute(fn channel -> channel end, pool: pool, timeout: 2_000)
    end
  end

  defp start_pool(port: port) do
    name = :"pubsub_grpc_test_pool_#{System.unique_integer([:positive])}"

    {:ok, config} =
      GrpcConnectionPool.Config.local(
        host: "localhost",
        port: port,
        pool_name: name,
        pool_size: 1
      )

    start_supervised!({GrpcConnectionPool, config})
    name
  end
end
