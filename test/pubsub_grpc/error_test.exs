defmodule PubsubGrpc.ErrorTest do
  use ExUnit.Case, async: true

  alias PubsubGrpc.Error

  describe "new/2,3" do
    test "creates error with code and message" do
      error = Error.new(:validation_error, "bad input")
      assert error.code == :validation_error
      assert error.message == "bad input"
      assert error.details == nil
      assert error.grpc_status == nil
    end

    test "creates error with details" do
      error = Error.new(:internal, "something broke", %{reason: :timeout})
      assert error.code == :internal
      assert error.details == %{reason: :timeout}
    end
  end

  describe "from_grpc_error/1" do
    test "maps known gRPC status codes" do
      codes = [
        {0, :ok},
        {1, :cancelled},
        {3, :invalid_argument},
        {4, :deadline_exceeded},
        {5, :not_found},
        {6, :already_exists},
        {7, :permission_denied},
        {8, :resource_exhausted},
        {13, :internal},
        {14, :unavailable},
        {16, :unauthenticated}
      ]

      for {status, expected_code} <- codes do
        grpc_error = %GRPC.RPCError{status: status, message: "test"}
        error = Error.from_grpc_error(grpc_error)
        assert error.code == expected_code, "status #{status} should map to #{expected_code}"
        assert error.grpc_status == status
        assert error.details == grpc_error
      end
    end

    test "maps unknown status codes to :unknown" do
      error = Error.from_grpc_error(%GRPC.RPCError{status: 999, message: "weird"})
      assert error.code == :unknown
      assert error.grpc_status == 999
    end

    test "handles nil message" do
      error = Error.from_grpc_error(%GRPC.RPCError{status: 5, message: nil})
      assert error.code == :not_found
      assert error.message =~ "gRPC error"
    end

    test "preserves original error in details" do
      original = %GRPC.RPCError{status: 6, message: "already exists"}
      error = Error.from_grpc_error(original)
      assert error.details == original
    end
  end

  describe "String.Chars" do
    test "formats error without gRPC status" do
      error = Error.new(:validation_error, "bad input")
      assert to_string(error) == "[validation_error] bad input"
    end

    test "formats error with gRPC status" do
      error = Error.from_grpc_error(%GRPC.RPCError{status: 5, message: "not found"})
      assert to_string(error) == "[not_found (gRPC 5)] not found"
    end
  end
end
