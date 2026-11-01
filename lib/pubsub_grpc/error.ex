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

  ## Codes

  Errors returned by the server carry the gRPC status name (`:not_found`,
  `:already_exists`, `:permission_denied`, ...; see `t:code/0`) and set
  `grpc_status`. Errors raised by the library itself have `grpc_status: nil`:

  - `:validation_error` - an argument or option was rejected before any request
  - `:connection_error` - no connection could be checked out from the pool
  - `:unavailable` - the gRPC connection process exited during the call (busy or dead)
  - `:unauthenticated` - no auth token could be obtained (Goth, gcloud)
  - `:deadline_exceeded` - the auth token fetch exceeded `:auth_timeout`
  - `:internal` - an `execute/2` callback returned an error that is neither a
    gRPC error nor a `PubsubGrpc.Error`

  ## Logging

  `details` holds raw upstream terms: gRPC errors with server-provided messages,
  Goth/HTTP errors, exception structs, connection-level reasons. They may contain
  credentials-adjacent data (account emails, credential file paths, request
  metadata) and are not size-bounded. **Do not log `details` verbatim.** Log
  `code`, `message` and `grpc_status` instead; `inspect/1` on this struct omits
  `details` for that reason.

  ## Examples

      case PubsubGrpc.create_topic("my-project", "my-topic") do
        {:ok, topic} -> topic
        {:error, %PubsubGrpc.Error{code: :already_exists}} -> "Topic already exists"
        {:error, %PubsubGrpc.Error{code: :unauthenticated}} -> "Auth failed"
        {:error, %PubsubGrpc.Error{} = err} -> "Error: \#{err}"
      end

  """

  @typedoc """
  The error category: a gRPC status name, or one of the library's own codes
  (`:validation_error`, `:connection_error`). See "Codes" in the moduledoc.
  """
  @type code ::
          :ok
          | :cancelled
          | :unknown
          | :invalid_argument
          | :deadline_exceeded
          | :not_found
          | :already_exists
          | :permission_denied
          | :resource_exhausted
          | :failed_precondition
          | :aborted
          | :out_of_range
          | :unimplemented
          | :internal
          | :unavailable
          | :data_loss
          | :unauthenticated
          | :validation_error
          | :connection_error

  @type t :: %__MODULE__{
          code: code(),
          message: String.t(),
          details: term(),
          grpc_status: non_neg_integer() | nil
        }

  @typedoc "A raw gRPC error as returned by grpc stubs (`%GRPC.RPCError{}`)."
  @type grpc_error :: %GRPC.RPCError{}

  @derive {Inspect, only: [:code, :message, :grpc_status]}
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
  @spec from_grpc_error(grpc_error()) :: t()
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
  @spec new(code(), String.t(), term()) :: t()
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
