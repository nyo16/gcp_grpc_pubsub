defmodule PubsubGrpc.Error do
  @moduledoc """
  Structured error type for PubsubGrpc operations.

  All errors returned by the library are wrapped in this struct, providing
  consistent error handling across authentication, validation, connection,
  and gRPC API errors.

  ## Fields

  - `code` - An atom categorizing the error (e.g., `:not_found`, `:validation_error`)
  - `message` - A human-readable error description
  - `details` - The original error term (e.g., `%GRPC.RPCError{}`, exception struct)
  - `grpc_status` - The integer gRPC status code when applicable, `nil` otherwise

  ## Examples

      case PubsubGrpc.create_topic("my-project", "my-topic") do
        {:ok, topic} -> topic
        {:error, %PubsubGrpc.Error{code: :already_exists}} -> "Topic already exists"
        {:error, %PubsubGrpc.Error{code: :unauthenticated}} -> "Auth failed"
        {:error, %PubsubGrpc.Error{} = err} -> "Error: \#{err}"
      end

  """

  @type t :: %__MODULE__{
          code: atom(),
          message: String.t(),
          details: term(),
          grpc_status: non_neg_integer() | nil
        }

  defstruct [:code, :message, :details, :grpc_status]

  @grpc_status_codes %{
    0 => :ok,
    1 => :cancelled,
    2 => :unknown,
    3 => :invalid_argument,
    4 => :deadline_exceeded,
    5 => :not_found,
    6 => :already_exists,
    7 => :permission_denied,
    8 => :resource_exhausted,
    9 => :failed_precondition,
    10 => :aborted,
    11 => :out_of_range,
    12 => :unimplemented,
    13 => :internal,
    14 => :unavailable,
    15 => :data_loss,
    16 => :unauthenticated
  }

  @doc """
  Creates a new error from a gRPC error.

  Maps the gRPC status code to a descriptive atom code and preserves
  the original error in `details`.
  """
  @spec from_grpc_error(GRPC.RPCError.t()) :: t()
  def from_grpc_error(%GRPC.RPCError{status: status, message: message} = error) do
    %__MODULE__{
      code: Map.get(@grpc_status_codes, status, :unknown),
      message: message || "gRPC error (status #{status})",
      details: error,
      grpc_status: status
    }
  end

  @doc """
  Creates a new error with the given code and message.
  """
  @spec new(atom(), String.t(), term()) :: t()
  def new(code, message, details \\ nil) do
    %__MODULE__{
      code: code,
      message: message,
      details: details
    }
  end

  defimpl String.Chars do
    def to_string(%PubsubGrpc.Error{code: code, message: message, grpc_status: nil}) do
      "[#{code}] #{message}"
    end

    def to_string(%PubsubGrpc.Error{code: code, message: message, grpc_status: status}) do
      "[#{code} (gRPC #{status})] #{message}"
    end
  end
end
