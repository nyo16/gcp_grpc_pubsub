defmodule PubsubGrpc.Schema do
  @moduledoc """
  Schema management for Google Cloud Pub/Sub.

  Provides functions for managing Pub/Sub schemas, which define the structure
  and format of messages. Supports Protocol Buffer and Avro formats.
  """

  alias PubsubGrpc.{Client, Error, Validation}

  @spec list_schemas(String.t(), keyword()) ::
          {:ok, %{schemas: list(), next_page_token: String.t()}} | {:error, Error.t()}
  def list_schemas(project_id, opts \\ []) do
    view = opts[:view] || :basic

    with {:ok, _} <- Validation.validate_project_id(project_id),
         {:ok, view_enum} <- Validation.validate_schema_view(view),
         {:ok, grpc_opts} <- grpc_opts() do
      project_path = "projects/#{project_id}"

      fn channel ->
        request = %Google.Pubsub.V1.ListSchemasRequest{
          parent: project_path,
          view: view_enum,
          page_size: Keyword.get(opts, :page_size, 0),
          page_token: Keyword.get(opts, :page_token, "")
        }

        Google.Pubsub.V1.SchemaService.Stub.list_schemas(channel, request, grpc_opts)
      end
      |> Client.execute()
      |> unwrap_list_result(:schemas, :next_page_token)
    end
  end

  @spec get_schema(String.t(), String.t(), keyword()) ::
          {:ok, Google.Pubsub.V1.Schema.t()} | {:error, Error.t()}
  def get_schema(project_id, schema_id, opts \\ []) do
    view = opts[:view] || :full

    with {:ok, _} <- Validation.validate_project_id(project_id),
         {:ok, _} <- Validation.validate_schema_id(schema_id),
         {:ok, view_enum} <- Validation.validate_schema_view(view),
         {:ok, grpc_opts} <- grpc_opts() do
      schema_path = schema_path(project_id, schema_id)

      fn channel ->
        request = %Google.Pubsub.V1.GetSchemaRequest{
          name: schema_path,
          view: view_enum
        }

        Google.Pubsub.V1.SchemaService.Stub.get_schema(channel, request, grpc_opts)
      end
      |> Client.execute()
      |> unwrap_result()
    end
  end

  @spec create_schema(String.t(), String.t(), :protocol_buffer | :avro, String.t()) ::
          {:ok, Google.Pubsub.V1.Schema.t()} | {:error, Error.t()}
  def create_schema(project_id, schema_id, type, definition) do
    with {:ok, _} <- Validation.validate_project_id(project_id),
         {:ok, _} <- Validation.validate_schema_id(schema_id),
         {:ok, type_enum} <- Validation.validate_schema_type(type),
         {:ok, grpc_opts} <- grpc_opts() do
      project_path = "projects/#{project_id}"

      fn channel ->
        schema = %Google.Pubsub.V1.Schema{
          type: type_enum,
          definition: definition
        }

        request = %Google.Pubsub.V1.CreateSchemaRequest{
          parent: project_path,
          schema_id: schema_id,
          schema: schema
        }

        Google.Pubsub.V1.SchemaService.Stub.create_schema(channel, request, grpc_opts)
      end
      |> Client.execute()
      |> unwrap_result()
    end
  end

  @spec delete_schema(String.t(), String.t()) :: :ok | {:error, Error.t()}
  def delete_schema(project_id, schema_id) do
    with {:ok, _} <- Validation.validate_project_id(project_id),
         {:ok, _} <- Validation.validate_schema_id(schema_id),
         {:ok, grpc_opts} <- grpc_opts() do
      schema_path = schema_path(project_id, schema_id)

      fn channel ->
        request = %Google.Pubsub.V1.DeleteSchemaRequest{name: schema_path}
        Google.Pubsub.V1.SchemaService.Stub.delete_schema(channel, request, grpc_opts)
      end
      |> Client.execute()
      |> unwrap_empty_result()
    end
  end

  @spec validate_schema(String.t(), :protocol_buffer | :avro, String.t()) ::
          {:ok, Google.Pubsub.V1.ValidateSchemaResponse.t()} | {:error, Error.t()}
  def validate_schema(project_id, type, definition) do
    with {:ok, _} <- Validation.validate_project_id(project_id),
         {:ok, type_enum} <- Validation.validate_schema_type(type),
         {:ok, grpc_opts} <- grpc_opts() do
      project_path = "projects/#{project_id}"

      fn channel ->
        schema = %Google.Pubsub.V1.Schema{
          type: type_enum,
          definition: definition
        }

        request = %Google.Pubsub.V1.ValidateSchemaRequest{
          parent: project_path,
          schema: schema
        }

        Google.Pubsub.V1.SchemaService.Stub.validate_schema(channel, request, grpc_opts)
      end
      |> Client.execute()
      |> unwrap_result()
    end
  end

  @spec list_schema_revisions(String.t(), String.t(), keyword()) ::
          {:ok, %{schemas: list(), next_page_token: String.t()}} | {:error, Error.t()}
  def list_schema_revisions(project_id, schema_id, opts \\ []) do
    view = opts[:view] || :basic

    with {:ok, _} <- Validation.validate_project_id(project_id),
         {:ok, _} <- Validation.validate_schema_id(schema_id),
         {:ok, view_enum} <- Validation.validate_schema_view(view),
         {:ok, grpc_opts} <- grpc_opts() do
      schema_path = schema_path(project_id, schema_id)

      fn channel ->
        request = %Google.Pubsub.V1.ListSchemaRevisionsRequest{
          name: schema_path,
          view: view_enum,
          page_size: Keyword.get(opts, :page_size, 0),
          page_token: Keyword.get(opts, :page_token, "")
        }

        Google.Pubsub.V1.SchemaService.Stub.list_schema_revisions(channel, request, grpc_opts)
      end
      |> Client.execute()
      |> unwrap_list_result(:schemas, :next_page_token)
    end
  end

  @doc """
  Validates a message against an existing schema by name.

  ## Parameters
  - `schema_name` - Schema ID or full resource name
  - `message` - Message bytes to validate
  - `encoding` - `:json` or `:binary`

  """
  @spec validate_message(String.t(), String.t(), binary(), :json | :binary) ::
          {:ok, Google.Pubsub.V1.ValidateMessageResponse.t()} | {:error, Error.t()}
  def validate_message(project_id, schema_name, message, encoding) do
    with {:ok, _} <- Validation.validate_project_id(project_id),
         {:ok, encoding_enum} <- Validation.validate_encoding(encoding),
         {:ok, grpc_opts} <- grpc_opts() do
      project_path = "projects/#{project_id}"

      # If schema_name doesn't contain a slash, treat it as a schema ID
      name =
        if String.contains?(schema_name, "/") do
          schema_name
        else
          schema_path(project_id, schema_name)
        end

      fn channel ->
        request = %Google.Pubsub.V1.ValidateMessageRequest{
          parent: project_path,
          schema_spec: {:name, name},
          message: message,
          encoding: encoding_enum
        }

        Google.Pubsub.V1.SchemaService.Stub.validate_message(channel, request, grpc_opts)
      end
      |> Client.execute()
      |> unwrap_result()
    end
  end

  @doc """
  Validates a message against an inline schema definition.

  ## Parameters
  - `type` - `:protocol_buffer` or `:avro`
  - `definition` - Schema definition string
  - `message` - Message bytes to validate
  - `encoding` - `:json` or `:binary`

  """
  @spec validate_message_with_schema(
          String.t(),
          :protocol_buffer | :avro,
          String.t(),
          binary(),
          :json | :binary
        ) ::
          {:ok, Google.Pubsub.V1.ValidateMessageResponse.t()} | {:error, Error.t()}
  def validate_message_with_schema(project_id, type, definition, message, encoding) do
    with {:ok, _} <- Validation.validate_project_id(project_id),
         {:ok, type_enum} <- Validation.validate_schema_type(type),
         {:ok, encoding_enum} <- Validation.validate_encoding(encoding),
         {:ok, grpc_opts} <- grpc_opts() do
      project_path = "projects/#{project_id}"

      fn channel ->
        schema = %Google.Pubsub.V1.Schema{
          type: type_enum,
          definition: definition
        }

        request = %Google.Pubsub.V1.ValidateMessageRequest{
          parent: project_path,
          schema_spec: {:schema, schema},
          message: message,
          encoding: encoding_enum
        }

        Google.Pubsub.V1.SchemaService.Stub.validate_message(channel, request, grpc_opts)
      end
      |> Client.execute()
      |> unwrap_result()
    end
  end

  # Private helpers

  defp grpc_opts do
    timeout = Application.get_env(:pubsub_grpc, :default_timeout, 30_000)

    case PubsubGrpc.Auth.request_opts() do
      {:ok, opts} -> {:ok, opts ++ [timeout: timeout]}
      {:error, _} = error -> error
    end
  end

  defp schema_path(project_id, schema_id) do
    "projects/#{project_id}/schemas/#{schema_id}"
  end

  defp unwrap_result({:ok, {:ok, result}}), do: {:ok, result}
  defp unwrap_result(other), do: unwrap_error(other)

  defp unwrap_empty_result({:ok, {:ok, %Google.Protobuf.Empty{}}}), do: :ok
  defp unwrap_empty_result(other), do: unwrap_error(other)

  defp unwrap_list_result({:ok, {:ok, response}}, items_key, token_key) do
    {:ok, %{items_key => Map.get(response, items_key), token_key => Map.get(response, token_key)}}
  end

  defp unwrap_list_result(other, _items_key, _token_key), do: unwrap_error(other)

  defp unwrap_error({:ok, {:error, %GRPC.RPCError{} = error}}) do
    {:error, Error.from_grpc_error(error)}
  end

  defp unwrap_error({:ok, {:error, error}}) do
    {:error, Error.new(:internal, "unexpected error: #{inspect(error)}", error)}
  end

  defp unwrap_error({:error, reason}) do
    {:error, Error.new(:connection_error, "connection error: #{inspect(reason)}", reason)}
  end
end
