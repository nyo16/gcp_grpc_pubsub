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
      package: [
        description: "Efficient Google Cloud Pub/Sub client using gRPC with NimblePool connection management",
        licenses: ["MIT"],
        links: %{"GitHub" => "https://github.com/your-username/pubsub_grpc"}
      ]
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
      {:googleapis_proto_ex, github: "nyo16/googleapis_proto_ex", branch: "master"},
      {:excoveralls, "~> 0.18", only: :test},
      {:ex_doc, "~> 0.31", only: :dev, runtime: false}
    ]
  end
end
