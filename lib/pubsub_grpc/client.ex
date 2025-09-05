defmodule PubsubGrpc.Client do
  @moduledoc """
  Client module for interacting with Google Cloud Pub/Sub using GRPC connections
  """

  @doc """
  Execute a GRPC operation using a connection from the pool
  """
  def execute(operation_fn, params \\ []) do
    PubsubGrpc.Connection.execute(PubsubGrpc.ConnectionPool, operation_fn, params)
  end

  @doc """
  Execute a function within a connection from the pool
  """
  def with_connection(fun) when is_function(fun, 1) do
    PubsubGrpc.Connection.with_connection(PubsubGrpc.ConnectionPool, fun)
  end
end