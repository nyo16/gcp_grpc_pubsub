defmodule PubsubGrpcTest do
  use ExUnit.Case
  doctest PubsubGrpc

  test "greets the world" do
    assert PubsubGrpc.hello() == :world
  end
end
