defmodule PubsubGrpc.MixProject do
  use Mix.Project

  def project do
    [
      app: :pubsub_grpc,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {PubsubGrpc.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:nimble_pool, "~> 1.1.0"},
      {:grpc, "~> 0.10.1"},
      {:googleapis_proto_ex, github: "nyo16/googleapis_proto_ex", branch: "master"}
    ]
  end
end
