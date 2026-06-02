defmodule PubsubGrpc.Schema do
  @moduledoc """
  Schema management for Google Cloud Pub/Sub.

  Provides functions for managing Pub/Sub schemas, which define the structure
  and format of messages. Supports Protocol Buffer and Avro formats.
  """

  alias Google.Pubsub.V1, as: PubsubV1
  alias PubsubGrpc.{Client, Error, Result, Telemetry, Validation}
  alias PubsubV1.SchemaService.Stub, as: SchemaStub

  @spec list_schemas(String.t(), keyword()) ::
          {:ok, %{schemas: list(), next_page_token: String.t()}} | {:error, Error.t()}
  def list_schemas(project_id, opts \\ []) do
    Telemetry.span(:list_schemas, %{project_id: project_id}, fn ->
      do_list_schemas(project_id, opts)
    end)
  end

  defp do_list_schemas(project_id, opts) do
    view = opts[:view] || :basic

    with {:ok, _} <- Validation.validate_project_id(project_id),
         {:ok, view_enum} <- Validation.validate_schema_view(view),
         {:ok, grpc_opts} <- PubsubGrpc.Auth.grpc_opts(opts) do
      project_path = "projects/#{project_id}"

      fn channel ->
        request = %PubsubV1.ListSchemasRequest{
          parent: project_path,
          view: view_enum,
          page_size: Keyword.get(opts, :page_size, 0),
          page_token: Keyword.get(opts, :page_token, "")
        }

        SchemaStub.list_schemas(channel, request, grpc_opts)
      end
      |> Client.execute()
      |> Result.unwrap_list(:schemas, :next_page_token)
    end
  end

  @spec get_schema(String.t(), String.t(), keyword()) ::
          {:ok, PubsubV1.Schema.t()} | {:error, Error.t()}
  def get_schema(project_id, schema_id, opts \\ []) do
    Telemetry.span(:get_schema, %{project_id: project_id, schema_id: schema_id}, fn ->
      do_get_schema(project_id, schema_id, opts)
    end)
  end

  defp do_get_schema(project_id, schema_id, opts) do
    view = opts[:view] || :full

    with {:ok, _} <- Validation.validate_project_id(project_id),
         {:ok, _} <- Validation.validate_schema_id(schema_id),
         {:ok, view_enum} <- Validation.validate_schema_view(view),
         {:ok, grpc_opts} <- PubsubGrpc.Auth.grpc_opts(opts) do
      schema_path = schema_path(project_id, schema_id)

      fn channel ->
        request = %PubsubV1.GetSchemaRequest{
          name: schema_path,
          view: view_enum
        }

        SchemaStub.get_schema(channel, request, grpc_opts)
      end
      |> Client.execute()
      |> Result.unwrap()
    end
  end

  @spec create_schema(String.t(), String.t(), :protocol_buffer | :avro, String.t()) ::
          {:ok, PubsubV1.Schema.t()} | {:error, Error.t()}
  def create_schema(project_id, schema_id, type, definition) do
    Telemetry.span(
      :create_schema,
      %{project_id: project_id, schema_id: schema_id, schema_type: type},
      fn -> do_create_schema(project_id, schema_id, type, definition) end
    )
  end

  defp do_create_schema(project_id, schema_id, type, definition) do
    with {:ok, _} <- Validation.validate_project_id(project_id),
         {:ok, _} <- Validation.validate_schema_id(schema_id),
         {:ok, type_enum} <- Validation.validate_schema_type(type),
         {:ok, grpc_opts} <- PubsubGrpc.Auth.grpc_opts() do
      project_path = "projects/#{project_id}"

      fn channel ->
        schema = %PubsubV1.Schema{
          type: type_enum,
          definition: definition
        }

        request = %PubsubV1.CreateSchemaRequest{
          parent: project_path,
          schema_id: schema_id,
          schema: schema
        }

        SchemaStub.create_schema(channel, request, grpc_opts)
      end
      |> Client.execute()
      |> Result.unwrap()
    end
  end

  @spec delete_schema(String.t(), String.t()) :: :ok | {:error, Error.t()}
  def delete_schema(project_id, schema_id) do
    Telemetry.span(:delete_schema, %{project_id: project_id, schema_id: schema_id}, fn ->
      do_delete_schema(project_id, schema_id)
    end)
  end

  defp do_delete_schema(project_id, schema_id) do
    with {:ok, _} <- Validation.validate_project_id(project_id),
         {:ok, _} <- Validation.validate_schema_id(schema_id),
         {:ok, grpc_opts} <- PubsubGrpc.Auth.grpc_opts() do
      schema_path = schema_path(project_id, schema_id)

      fn channel ->
        request = %PubsubV1.DeleteSchemaRequest{name: schema_path}
        SchemaStub.delete_schema(channel, request, grpc_opts)
      end
      |> Client.execute()
      |> Result.unwrap_empty()
    end
  end

  @spec validate_schema(String.t(), :protocol_buffer | :avro, String.t()) ::
          {:ok, PubsubV1.ValidateSchemaResponse.t()} | {:error, Error.t()}
  def validate_schema(project_id, type, definition) do
    Telemetry.span(:validate_schema, %{project_id: project_id, schema_type: type}, fn ->
      do_validate_schema(project_id, type, definition)
    end)
  end

  defp do_validate_schema(project_id, type, definition) do
    with {:ok, _} <- Validation.validate_project_id(project_id),
         {:ok, type_enum} <- Validation.validate_schema_type(type),
         {:ok, grpc_opts} <- PubsubGrpc.Auth.grpc_opts() do
      project_path = "projects/#{project_id}"

      fn channel ->
        schema = %PubsubV1.Schema{
          type: type_enum,
          definition: definition
        }

        request = %PubsubV1.ValidateSchemaRequest{
          parent: project_path,
          schema: schema
        }

        SchemaStub.validate_schema(channel, request, grpc_opts)
      end
      |> Client.execute()
      |> Result.unwrap()
    end
  end

  @spec list_schema_revisions(String.t(), String.t(), keyword()) ::
          {:ok, %{schemas: list(), next_page_token: String.t()}} | {:error, Error.t()}
  def list_schema_revisions(project_id, schema_id, opts \\ []) do
    Telemetry.span(
      :list_schema_revisions,
      %{project_id: project_id, schema_id: schema_id},
      fn -> do_list_schema_revisions(project_id, schema_id, opts) end
    )
  end

  defp do_list_schema_revisions(project_id, schema_id, opts) do
    view = opts[:view] || :basic

    with {:ok, _} <- Validation.validate_project_id(project_id),
         {:ok, _} <- Validation.validate_schema_id(schema_id),
         {:ok, view_enum} <- Validation.validate_schema_view(view),
         {:ok, grpc_opts} <- PubsubGrpc.Auth.grpc_opts(opts) do
      schema_path = schema_path(project_id, schema_id)

      fn channel ->
        request = %PubsubV1.ListSchemaRevisionsRequest{
          name: schema_path,
          view: view_enum,
          page_size: Keyword.get(opts, :page_size, 0),
          page_token: Keyword.get(opts, :page_token, "")
        }

        SchemaStub.list_schema_revisions(channel, request, grpc_opts)
      end
      |> Client.execute()
      |> Result.unwrap_list(:schemas, :next_page_token)
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
          {:ok, PubsubV1.ValidateMessageResponse.t()} | {:error, Error.t()}
  def validate_message(project_id, schema_name, message, encoding) do
    Telemetry.span(
      :validate_message,
      %{project_id: project_id, schema_name: schema_name, encoding: encoding},
      fn -> do_validate_message(project_id, schema_name, message, encoding) end
    )
  end

  defp do_validate_message(project_id, schema_name, message, encoding) do
    with {:ok, _} <- Validation.validate_project_id(project_id),
         {:ok, encoding_enum} <- Validation.validate_encoding(encoding),
         {:ok, grpc_opts} <- PubsubGrpc.Auth.grpc_opts() do
      project_path = "projects/#{project_id}"

      # If schema_name doesn't contain a slash, treat it as a schema ID
      name =
        if String.contains?(schema_name, "/") do
          schema_name
        else
          schema_path(project_id, schema_name)
        end

      fn channel ->
        request = %PubsubV1.ValidateMessageRequest{
          parent: project_path,
          schema_spec: {:name, name},
          message: message,
          encoding: encoding_enum
        }

        SchemaStub.validate_message(channel, request, grpc_opts)
      end
      |> Client.execute()
      |> Result.unwrap()
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
          {:ok, PubsubV1.ValidateMessageResponse.t()} | {:error, Error.t()}
  def validate_message_with_schema(project_id, type, definition, message, encoding) do
    Telemetry.span(
      :validate_message_with_schema,
      %{project_id: project_id, schema_type: type, encoding: encoding},
      fn -> do_validate_message_with_schema(project_id, type, definition, message, encoding) end
    )
  end

  defp do_validate_message_with_schema(project_id, type, definition, message, encoding) do
    with {:ok, _} <- Validation.validate_project_id(project_id),
         {:ok, type_enum} <- Validation.validate_schema_type(type),
         {:ok, encoding_enum} <- Validation.validate_encoding(encoding),
         {:ok, grpc_opts} <- PubsubGrpc.Auth.grpc_opts() do
      project_path = "projects/#{project_id}"

      fn channel ->
        schema = %PubsubV1.Schema{
          type: type_enum,
          definition: definition
        }

        request = %PubsubV1.ValidateMessageRequest{
          parent: project_path,
          schema_spec: {:schema, schema},
          message: message,
          encoding: encoding_enum
        }

        SchemaStub.validate_message(channel, request, grpc_opts)
      end
      |> Client.execute()
      |> Result.unwrap()
    end
  end

  # Private helpers

  defp schema_path(project_id, schema_id) do
    "projects/#{project_id}/schemas/#{schema_id}"
  end
end
