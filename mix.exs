defmodule PubsubGrpc.MixProject do
  use Mix.Project

  @version "0.5.0"
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
      dialyzer: [
        plt_local_path: "priv/plts",
        plt_core_path: "priv/plts",
        plt_add_apps: [:mix, :ex_unit]
      ],

      # Accepted advisories, see CHANGELOG.md "Known advisories": cowlib/gun are pulled in
      # by grpc's gun adapter and the vulnerable code paths are not reachable from this library.
      # Review this list on every dependency bump (stale entries only warn).
      hex: [
        ignore_advisories: ["EEF-CVE-2026-43966", "EEF-CVE-2026-43969", "GHSA-w4f7-4cxr-rv3c"]
      ],

      # Docs
      name: "PubsubGrpc",
      description: "Efficient Google Cloud Pub/Sub client using gRPC with connection pooling",
      source_url: @source_url,
      docs: [
        main: "PubsubGrpc",
        extras: ["README.md", "CHANGELOG.md", "LICENSE"],
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

  # dev/ holds the repo-only `mix emulator.*` tasks: compiled in :dev and :test, never
  # in :prod (how dependents compile this library) and not listed in package files.
  defp elixirc_paths(:test), do: ["lib", "dev", "test/support"]
  defp elixirc_paths(:dev), do: ["lib", "dev"]
  defp elixirc_paths(_), do: ["lib"]

  defp package do
    [
      description:
        "Efficient Google Cloud Pub/Sub client using gRPC with GrpcConnectionPool library",
      licenses: ["Apache-2.0"],
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "#{@source_url}/blob/master/CHANGELOG.md"
      },
      files: ~w(lib .formatter.exs mix.exs README* LICENSE* CHANGELOG*)
    ]
  end

  defp deps do
    [
      {:grpc_connection_pool, "~> 0.5.3"},
      {:telemetry, "~> 1.0"},
      {:excoveralls, "~> 0.18", only: :test},
      {:ex_doc, "~> 0.40", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:goth, "~> 1.4", optional: true}
    ]
  end
end
