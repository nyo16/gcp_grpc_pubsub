defmodule PubsubGrpc.MixProject do
  use Mix.Project

  @version "0.4.0"
  @source_url "https://github.com/nyo16/gcp_grpc_pubsub"

  def project do
    [
      app: :pubsub_grpc,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      test_coverage: [tool: ExCoveralls],
      elixirc_paths: elixirc_paths(Mix.env()),

      # Docs
      name: "PubsubGrpc",
      description: "Efficient Google Cloud Pub/Sub client using gRPC with connection pooling",
      source_url: @source_url,
      docs: [
        main: "PubsubGrpc",
        extras: ["README.md", "CHANGELOG.md"],
        source_ref: "v#{@version}"
      ],
      package: package()
    ]
  end

  def cli do
    [
      preferred_envs: [
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.post": :test,
        "coveralls.html": :test,
        "coveralls.cobertura": :test
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {PubsubGrpc.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp package do
    [
      description:
        "Efficient Google Cloud Pub/Sub client using gRPC with GrpcConnectionPool library",
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "#{@source_url}/blob/master/CHANGELOG.md"
      },
      files: ~w(lib .formatter.exs mix.exs README* LICENSE* CHANGELOG*)
    ]
  end

  defp deps do
    [
      {:grpc_connection_pool, "0.3.0"},
      {:excoveralls, "~> 0.18", only: :test},
      {:ex_doc, "~> 0.31", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:goth, "~> 1.4", optional: true}
    ]
  end
end
