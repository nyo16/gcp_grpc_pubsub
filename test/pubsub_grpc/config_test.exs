defmodule PubsubGrpc.ConfigTest do
  use ExUnit.Case, async: true

  alias PubsubGrpc.Config

  @local_endpoint [type: :local, host: "localhost", port: 8085]

  describe "resolve/1 with the legacy config" do
    test "a keyword :emulator gives a :local endpoint and the default pool name" do
      resolved = Config.resolve(emulator: [host: "emu", port: 9999], default_pool_size: 2)

      assert %{endpoint_type: :local, source: :legacy, pool_name: PubsubGrpc.ConnectionPool} =
               resolved

      assert %{host: "emu", port: 9999, ssl: nil} = resolved.pool_config.endpoint
      assert resolved.pool_config.pool.size == 2
    end

    test "without :emulator, uses the production endpoint with verified TLS" do
      resolved = Config.resolve([])

      assert resolved.endpoint_type == :production
      assert %{host: "pubsub.googleapis.com", port: 443} = resolved.pool_config.endpoint
      assert_verified_tls(resolved.pool_config.endpoint.ssl)
    end

    test "a non-keyword :emulator value is not treated as emulator mode" do
      for value <- [true, false, "localhost:8085"] do
        assert %{endpoint_type: :production} = Config.resolve(emulator: value)
      end
    end
  end

  describe "resolve/1 with config :pubsub_grpc, GrpcConnectionPool" do
    test "type: :local is the emulator, with no :emulator key needed" do
      resolved = Config.resolve([{GrpcConnectionPool, [endpoint: @local_endpoint]}])

      assert %{endpoint_type: :local, source: :app_env} = resolved
      assert resolved.pool_name == PubsubGrpc.ConnectionPool
      assert resolved.pool_config.pool.name == PubsubGrpc.ConnectionPool
    end

    test "uses the configured pool name" do
      resolved =
        Config.resolve([
          {GrpcConnectionPool, [endpoint: @local_endpoint, pool: [name: MyApp.PubsubPool]]}
        ])

      assert resolved.pool_name == MyApp.PubsubPool
    end

    test "a production endpoint without :ssl gets verified TLS defaults" do
      resolved =
        Config.resolve([
          {GrpcConnectionPool,
           [endpoint: [type: :production, host: "pubsub.googleapis.com", port: 443]]}
        ])

      assert resolved.endpoint_type == :production
      assert_verified_tls(resolved.pool_config.endpoint.ssl)
    end

    test "an empty ssl: [] is replaced with verified TLS defaults" do
      resolved =
        Config.resolve([
          {GrpcConnectionPool,
           [endpoint: [type: :production, host: "pubsub.googleapis.com", port: 443, ssl: []]]}
        ])

      assert_verified_tls(resolved.pool_config.endpoint.ssl)
    end

    test "an explicit non-empty :ssl is used as given" do
      ssl = [verify: :verify_peer, cacertfile: "/etc/ssl/ca.pem"]

      resolved =
        Config.resolve([
          {GrpcConnectionPool,
           [endpoint: [type: :production, host: "pubsub.googleapis.com", port: 443, ssl: ssl]]}
        ])

      assert resolved.pool_config.endpoint.ssl == ssl
    end

    test "a non-local endpoint with :credentials is accepted" do
      credentials = GRPC.Credential.new(ssl: [verify: :verify_peer])

      resolved =
        Config.resolve([
          {GrpcConnectionPool,
           [
             endpoint: [
               type: :custom,
               host: "pubsub.example.com",
               port: 443,
               credentials: credentials
             ]
           ]}
        ])

      assert resolved.endpoint_type == :production
      assert resolved.pool_config.endpoint.credentials == credentials
    end
  end

  describe "resolve/1 refuses unsafe or invalid configuration" do
    test "a non-local endpoint without TLS raises" do
      error =
        assert_raise ArgumentError, fn ->
          Config.resolve([
            {GrpcConnectionPool,
             [endpoint: [type: :custom, host: "pubsub.example.com", port: 8681]]}
          ])
        end

      message = Exception.message(error)
      assert message =~ "refusing to connect to pubsub.example.com:8681"
      assert message =~ "without TLS"
      assert message =~ "type: :local"
    end

    test "ssl: false on a production endpoint raises" do
      assert_raise ArgumentError, ~r/without TLS/, fn ->
        Config.resolve([
          {GrpcConnectionPool,
           [endpoint: [type: :production, host: "pubsub.googleapis.com", port: 443, ssl: false]]}
        ])
      end
    end

    test "a present but invalid config raises instead of falling back to production" do
      assert_raise ArgumentError,
                   ~r/invalid `config :pubsub_grpc, GrpcConnectionPool` \(.*host is required/,
                   fn ->
                     Config.resolve([
                       {GrpcConnectionPool, [endpoint: [type: :local, port: 8085]]}
                     ])
                   end
    end

    test "a config that is not a keyword list raises" do
      assert_raise ArgumentError, ~r/expected a keyword list/, fn ->
        Config.resolve([{GrpcConnectionPool, %{endpoint: @local_endpoint}}])
      end
    end

    test "an invalid :auth_timeout raises" do
      for value <- [0, -500, :infinity, "5000", 1.5] do
        assert_raise ArgumentError, ~r/:auth_timeout.*positive integer/, fn ->
          Config.resolve(auth_timeout: value)
        end
      end

      assert %{endpoint_type: :production} = Config.resolve(auth_timeout: 5_000)
    end
  end

  describe "production_ssl_opts/1" do
    test ":ssl_opts are merged over the verified defaults" do
      ssl = Config.production_ssl_opts(ssl_opts: [versions: [:"tlsv1.3"]])

      assert ssl[:versions] == [:"tlsv1.3"]
      assert_verified_tls(ssl)
    end

    test "a user :cacertfile replaces the default :cacerts" do
      ssl = Config.production_ssl_opts(ssl_opts: [cacertfile: "/etc/ssl/ca.pem"])

      assert ssl[:cacertfile] == "/etc/ssl/ca.pem"
      refute Keyword.has_key?(ssl, :cacerts)
      assert ssl[:verify] == :verify_peer
    end
  end

  describe "PubsubGrpc.Application.children/2" do
    setup do
      %{resolved: Config.resolve([{GrpcConnectionPool, [endpoint: @local_endpoint]}])}
    end

    test "starts the pool by default", %{resolved: resolved} do
      assert {GrpcConnectionPool, resolved.pool_config} in PubsubGrpc.Application.children(
               resolved,
               []
             )
    end

    test "start_pool: false leaves the pool out", %{resolved: resolved} do
      children = PubsubGrpc.Application.children(resolved, start_pool: false)

      refute Enum.any?(children, &match?({GrpcConnectionPool, _}, &1))
      assert PubsubGrpc.Auth.Cache in children
    end
  end

  describe "PubsubGrpc.child_spec/1" do
    test "starts the configured pool under the PubsubGrpc id" do
      assert %{id: PubsubGrpc, type: :supervisor, start: {_mod, :start_link, [config | _]}} =
               PubsubGrpc.child_spec([])

      assert config == Config.pool_config()
      assert Supervisor.child_spec(PubsubGrpc, []).id == PubsubGrpc
    end
  end

  defp assert_verified_tls(ssl) do
    assert ssl[:verify] == :verify_peer
    assert is_list(ssl[:cacerts]) and ssl[:cacerts] != []
    assert Keyword.has_key?(ssl, :customize_hostname_check)
  end
end
