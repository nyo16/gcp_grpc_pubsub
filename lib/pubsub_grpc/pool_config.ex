defmodule PubsubGrpc.PoolConfig do
  @moduledoc """
  Configuration module for PubsubGrpc connection pooling.

  This module provides a unified configuration interface that works with both
  production Google Cloud Pub/Sub and local emulator environments.

  ## Configuration Options

  - `:endpoint` - Connection endpoint configuration
    - `:type` - Either `:production` or `:emulator`  
    - `:host` - Hostname (for emulator or custom endpoints)
    - `:port` - Port number (for emulator or custom endpoints)
    - `:project_id` - Google Cloud project ID (for emulator)
    - `:ssl` - SSL configuration (default: auto-configured based on type)
    - `:retry_config` - Retry configuration for connection failures
  - `:pool` - Pool configuration
    - `:size` - Number of connections in pool (default: 5)
    - `:name` - Pool name (default: auto-generated)
    - `:checkout_timeout` - Timeout for checking out connections (default: 15_000)
  - `:connection` - Connection-specific settings
    - `:keepalive` - Keepalive interval in milliseconds (default: 30_000)
    - `:health_check` - Whether to enable connection health checks (default: true)
    - `:ping_interval` - Interval to send ping to keep connection warm (default: 25_000)

  ## Examples

  ### Production Configuration

      config = %PubsubGrpc.PoolConfig{
        endpoint: %{
          type: :production
        },
        pool: %{
          size: 10,
          name: MyApp.PubSubPool
        }
      }

  ### Emulator Configuration

      config = %PubsubGrpc.PoolConfig{
        endpoint: %{
          type: :emulator,
          host: "localhost",
          port: 8085,
          project_id: "test-project"
        },
        pool: %{
          size: 3
        }
      }

  """

  @type endpoint_type :: :production | :emulator | :custom

  @type endpoint_config :: %{
          type: endpoint_type(),
          host: String.t() | nil,
          port: pos_integer() | nil,
          project_id: String.t() | nil,
          ssl: keyword() | boolean() | nil,
          retry_config: retry_config() | nil
        }

  @type pool_config :: %{
          size: pos_integer(),
          name: atom() | nil,
          checkout_timeout: pos_integer()
        }

  @type connection_config :: %{
          keepalive: pos_integer(),
          health_check: boolean(),
          ping_interval: pos_integer() | nil
        }

  @type retry_config :: %{
          max_attempts: pos_integer(),
          base_delay: pos_integer(),
          max_delay: pos_integer()
        }

  @type t :: %__MODULE__{
          endpoint: endpoint_config(),
          pool: pool_config(),
          connection: connection_config()
        }

  defstruct endpoint: %{
              type: :production,
              host: nil,
              port: nil,
              project_id: nil,
              ssl: nil,
              retry_config: nil
            },
            pool: %{
              size: 5,
              name: nil,
              checkout_timeout: 15_000
            },
            connection: %{
              keepalive: 30_000,
              health_check: true,
              ping_interval: 25_000
            }

  @doc """
  Creates a new pool configuration from keyword options or environment variables.
  """
  @spec new(keyword()) :: {:ok, t()} | {:error, String.t()}
  def new(opts \\ []) do
    try do
      config = %__MODULE__{
        endpoint: build_endpoint_config(opts[:endpoint] || []),
        pool: build_pool_config(opts[:pool] || []),
        connection: build_connection_config(opts[:connection] || [])
      }

      {:ok, config}
    rescue
      error -> {:error, "Invalid configuration: #{Exception.message(error)}"}
    end
  end

  @doc """
  Creates a pool configuration from application environment variables.
  """
  @spec from_env(atom(), atom()) :: {:ok, t()} | {:error, String.t()}
  def from_env(app, key \\ PubsubGrpc) do
    case Application.get_env(app, key) do
      nil -> new([])
      config when is_list(config) -> new(config)
      _ -> {:error, "Invalid configuration format in application environment"}
    end
  end

  @doc """
  Creates a production configuration with default Google Cloud settings.
  """
  @spec production(keyword()) :: {:ok, t()}
  def production(opts \\ []) do
    new([
      endpoint: [type: :production],
      pool: [
        size: opts[:pool_size] || 5,
        name: opts[:pool_name]
      ]
    ])
  end

  @doc """
  Creates an emulator configuration for local development.
  """
  @spec emulator(keyword()) :: {:ok, t()} | {:error, String.t()}
  def emulator(opts) do
    project_id = opts[:project_id]

    if is_nil(project_id) do
      {:error, "project_id is required for emulator configuration"}
    else
      new([
        endpoint: [
          type: :emulator,
          host: opts[:host] || "localhost",
          port: opts[:port] || 8085,
          project_id: project_id,
          retry_config: [
            max_attempts: 3,
            base_delay: 1000,
            max_delay: 5000
          ]
        ],
        pool: [
          size: opts[:pool_size] || 3,
          name: opts[:pool_name]
        ]
      ])
    end
  end

  @doc """
  Gets the GRPC connection endpoint from the configuration.
  """
  @spec get_endpoint(t()) :: {String.t(), pos_integer(), keyword()}
  def get_endpoint(%__MODULE__{endpoint: endpoint, connection: connection}) do
    case endpoint.type do
      :production ->
        {"pubsub.googleapis.com", 443,
         [
           cred: GRPC.Credential.new(ssl: endpoint.ssl || []),
           adapter_opts: [
             http2_opts: %{keepalive: connection.keepalive}
           ]
         ]}

      :emulator ->
        {endpoint.host, endpoint.port,
         [
           adapter_opts: [
             http2_opts: %{keepalive: connection.keepalive}
           ]
         ]}

      :custom ->
        opts =
          if endpoint.ssl do
            [
              cred: GRPC.Credential.new(ssl: endpoint.ssl),
              adapter_opts: [
                http2_opts: %{keepalive: connection.keepalive}
              ]
            ]
          else
            [
              adapter_opts: [
                http2_opts: %{keepalive: connection.keepalive}
              ]
            ]
          end

        {endpoint.host, endpoint.port, opts}
    end
  end

  @doc """
  Gets the retry configuration for connection attempts.
  """
  @spec get_retry_config(t()) :: retry_config() | nil
  def get_retry_config(%__MODULE__{endpoint: endpoint}) do
    endpoint.retry_config
  end

  # Private functions

  defp build_endpoint_config(opts) do
    type = opts[:type] || :production

    base = %{
      type: type,
      host: opts[:host],
      port: opts[:port],
      project_id: opts[:project_id],
      ssl: opts[:ssl],
      retry_config: build_retry_config(opts[:retry_config] || [])
    }

    validate_endpoint_config!(base)
    base
  end

  defp build_pool_config(opts) do
    %{
      size: opts[:size] || 5,
      name: opts[:name],
      checkout_timeout: opts[:checkout_timeout] || 15_000
    }
  end

  defp build_connection_config(opts) do
    %{
      keepalive: opts[:keepalive] || 30_000,
      health_check: opts[:health_check] != false,
      ping_interval: opts[:ping_interval] || 25_000
    }
  end

  defp build_retry_config([]), do: nil

  defp build_retry_config(opts) do
    %{
      max_attempts: opts[:max_attempts] || 3,
      base_delay: opts[:base_delay] || 1000,
      max_delay: opts[:max_delay] || 5000
    }
  end

  defp validate_endpoint_config!(%{type: :emulator, host: nil}),
    do: raise(ArgumentError, "host is required for emulator configuration")

  defp validate_endpoint_config!(%{type: :emulator, port: nil}),
    do: raise(ArgumentError, "port is required for emulator configuration")

  defp validate_endpoint_config!(%{type: :custom, host: nil}),
    do: raise(ArgumentError, "host is required for custom endpoint configuration")

  defp validate_endpoint_config!(%{type: :custom, port: nil}),
    do: raise(ArgumentError, "port is required for custom endpoint configuration")

  defp validate_endpoint_config!(_), do: :ok
end