defmodule PubsubGrpc.MixProject do
  use Mix.Project

  def project do
    [
      app: :pubsub_grpc,
      version: "0.2.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      test_coverage: [tool: ExCoveralls],
      preferred_cli_env: [
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.post": :test,
        "coveralls.html": :test,
        "coveralls.cobertura": :test
      ],

      # Docs
      name: "PubsubGrpc",
      description: "Efficient Google Cloud Pub/Sub client using gRPC with connection pooling",
      docs: [
        main: "PubsubGrpc",
        extras: ["README.md"]
      ],
      package: package()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {PubsubGrpc.Application, []}
    ]
  end

  defp package do
    [
      description:
        "Efficient Google Cloud Pub/Sub client using gRPC with Poolex connection management",
      licenses: ["MIT"],
      links: %{"GitHub" => "https://github.com/nyo16/gcp_grpc_pubsub"},
      files: ~w(lib .formatter.exs mix.exs README* LICENSE*)
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:poolex, "~> 1.4.1"},
      {:grpc, "~> 0.10.2"},
      {:googleapis_proto_ex, "~> 0.3.0"},
      {:excoveralls, "~> 0.18", only: :test},
      {:ex_doc, "~> 0.31", only: :dev, runtime: false},
      {:goth, "~> 1.4", optional: true}
    ]
  end
end
