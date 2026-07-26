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

      # Docs
      name: "PubsubGrpc",
      description: "Efficient Google Cloud Pub/Sub client using gRPC with connection pooling",
      source_url: @source_url,
      docs: [
        main: "PubsubGrpc",
        extras: ["README.md", "CHANGELOG.md"],
        source_ref: "v#{@version}",
        # The generated `Google.Pubsub.V1.*` protobuf modules and the internal
        # `PubsubGrpc.Validation` are all `@moduledoc false`, so ExDoc has nothing to link
        # to. They still belong in the typespecs and CHANGELOG as plain code text, so skip
        # autolinking to them rather than publishing dozens of generated protobuf modules
        # just to satisfy the linker. This suppresses the dead links in prose.
        skip_code_autolink_to: fn ref ->
          String.starts_with?(ref, "Google.Pubsub.V1.") or
            String.starts_with?(ref, "PubsubGrpc.Validation")
        end,
        # Warnings for hidden references in *typespecs* are gated separately, and ExDoc
        # matches them on the location of the reference rather than its target — so the
        # functions whose specs return the generated protobuf structs have to be listed
        # explicitly. Kept at function granularity (not whole files) so a genuine typo
        # elsewhere in these modules still warns.
        skip_undefined_reference_warnings_on: [
          "PubsubGrpc.create_topic/2",
          "PubsubGrpc.get_topic/2",
          "PubsubGrpc.create_subscription/4",
          "PubsubGrpc.get_subscription/2",
          "PubsubGrpc.Schema.create_schema/4",
          "PubsubGrpc.Schema.get_schema/3",
          "PubsubGrpc.Schema.validate_schema/3",
          "PubsubGrpc.Schema.validate_message/4",
          "PubsubGrpc.Schema.validate_message_with_schema/5"
        ]
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
      {:grpc_connection_pool, "~> 0.5.1"},
      {:telemetry, "~> 1.0"},
      {:excoveralls, "~> 0.18", only: :test},
      {:ex_doc, "~> 0.31", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:goth, "~> 1.4", optional: true}
    ]
  end
end
