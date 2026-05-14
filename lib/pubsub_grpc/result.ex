defmodule PubsubGrpc.Result do
  @moduledoc false
  # Shared helpers for normalizing gRPC client return values into
  # `{:ok, _} | {:error, %PubsubGrpc.Error{}}`. Used by `PubsubGrpc` and
  # `PubsubGrpc.Schema` so error mapping stays consistent.

  alias PubsubGrpc.Error

  @type client_result :: {:ok, {:ok, term()} | {:error, term()}} | {:error, term()}

  @spec unwrap(client_result()) :: {:ok, term()} | {:error, Error.t()}
  def unwrap({:ok, {:ok, result}}), do: {:ok, result}
  def unwrap(other), do: unwrap_error(other)

  @spec unwrap_empty(client_result()) :: :ok | {:error, Error.t()}
  def unwrap_empty({:ok, {:ok, %Google.Protobuf.Empty{}}}), do: :ok
  def unwrap_empty(other), do: unwrap_error(other)

  @spec unwrap_list(client_result(), atom(), atom()) ::
          {:ok, map()} | {:error, Error.t()}
  def unwrap_list({:ok, {:ok, response}}, items_key, token_key) do
    {:ok, %{items_key => Map.get(response, items_key), token_key => Map.get(response, token_key)}}
  end

  def unwrap_list(other, _items_key, _token_key), do: unwrap_error(other)

  @spec unwrap_error(client_result()) :: {:error, Error.t()}
  def unwrap_error({:ok, {:error, %GRPC.RPCError{} = error}}) do
    {:error, Error.from_grpc_error(error)}
  end

  def unwrap_error({:ok, {:error, error}}) do
    {:error, Error.new(:internal, "unexpected gRPC error", error)}
  end

  def unwrap_error({:error, reason}) do
    {:error, Error.new(:connection_error, "connection error", reason)}
  end
end
