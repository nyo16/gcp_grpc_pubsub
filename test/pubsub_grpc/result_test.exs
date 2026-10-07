defmodule PubsubGrpc.ResultTest do
  use ExUnit.Case, async: true

  alias PubsubGrpc.{Error, Result}

  describe "unwrap_any/1" do
    test "unwraps a nested {:ok, result}" do
      assert {:ok, :value} = Result.unwrap_any({:ok, {:ok, :value}})
    end

    test "maps a nested gRPC error to a structured error" do
      rpc_error = %GRPC.RPCError{status: 5, message: "topic not found"}

      assert {:error, %Error{code: :not_found, message: "topic not found", details: ^rpc_error}} =
               Result.unwrap_any({:ok, {:error, rpc_error}})
    end

    test "maps a nested non-gRPC error to an :internal error" do
      assert {:error, %Error{code: :internal, details: :boom}} =
               Result.unwrap_any({:ok, {:error, :boom}})
    end

    test "passes a structured error from the callback through unchanged" do
      error = Error.new(:unauthenticated, "no token")
      assert {:error, ^error} = Result.unwrap_any({:ok, {:error, error}})
    end

    test "maps a checkout error to a :connection_error" do
      assert {:error, %Error{code: :connection_error, details: :not_connected}} =
               Result.unwrap_any({:error, :not_connected})
    end

    test "wraps any other callback value in {:ok, value}" do
      assert {:ok, :ok} = Result.unwrap_any({:ok, :ok})
      assert {:ok, %{count: 2}} = Result.unwrap_any({:ok, %{count: 2}})
      assert {:ok, nil} = Result.unwrap_any({:ok, nil})
      assert {:ok, {:ok, :a, :b}} = Result.unwrap_any({:ok, {:ok, :a, :b}})
    end
  end

  @rpc_not_found %GRPC.RPCError{status: 5, message: "missing"}

  describe "unwrap/1" do
    test "unwraps a successful result" do
      assert {:ok, :value} = Result.unwrap({:ok, {:ok, :value}})
    end

    test "maps every error shape" do
      assert {:error, %Error{code: :not_found}} = Result.unwrap({:ok, {:error, @rpc_not_found}})
      assert {:error, %Error{code: :internal}} = Result.unwrap({:ok, {:error, :boom}})
      assert {:error, %Error{code: :connection_error}} = Result.unwrap({:error, :not_connected})
    end
  end

  describe "unwrap_empty/1" do
    test "turns an Empty response into :ok" do
      assert :ok = Result.unwrap_empty({:ok, {:ok, %Google.Protobuf.Empty{}}})
    end

    test "maps errors" do
      assert {:error, %Error{code: :not_found}} =
               Result.unwrap_empty({:ok, {:error, @rpc_not_found}})

      assert {:error, %Error{code: :connection_error}} = Result.unwrap_empty({:error, :closed})
    end
  end

  describe "unwrap_list/3" do
    test "extracts the items and the page token" do
      response = %Google.Pubsub.V1.ListTopicsResponse{
        topics: [%Google.Pubsub.V1.Topic{name: "t"}],
        next_page_token: "next"
      }

      assert {:ok, %{topics: [%Google.Pubsub.V1.Topic{name: "t"}], next_page_token: "next"}} =
               Result.unwrap_list({:ok, {:ok, response}}, :topics, :next_page_token)
    end

    test "maps errors" do
      assert {:error, %Error{code: :internal, details: :boom}} =
               Result.unwrap_list({:ok, {:error, :boom}}, :topics, :next_page_token)

      assert {:error, %Error{code: :connection_error, details: :timeout}} =
               Result.unwrap_list({:error, :timeout}, :topics, :next_page_token)
    end
  end

  describe "unwrap_error/1" do
    # Status 16 (UNAUTHENTICATED) also clears the global token cache, so it is
    # tested in the synchronous PubsubGrpc.AuthTest.
    test "maps a gRPC error through Error.from_grpc_error/1" do
      assert {:error, %Error{code: :not_found, message: "missing", details: @rpc_not_found}} =
               Result.unwrap_error({:ok, {:error, @rpc_not_found}})
    end

    test "maps a non-gRPC callback error to :internal" do
      assert {:error, %Error{code: :internal, message: "unexpected gRPC error", details: :boom}} =
               Result.unwrap_error({:ok, {:error, :boom}})
    end

    test "maps a checkout error to :connection_error" do
      assert {:error, %Error{code: :connection_error, message: "connection error", details: :x}} =
               Result.unwrap_error({:error, :x})
    end
  end
end
