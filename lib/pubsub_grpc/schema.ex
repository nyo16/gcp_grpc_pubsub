defmodule PubsubGrpc.Schema do
  @moduledoc false

  # Schema operations. Public API and docs: the `PubsubGrpc` delegates.

  alias Google.Pubsub.V1, as: PubsubV1
  alias PubsubGrpc.{Error, Request, Result, Telemetry, Validation}
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
         {:ok, view_enum} <- Validation.validate_schema_view(view) do
      request = %PubsubV1.ListSchemasRequest{
        parent: Request.project_path(project_id),
        view: view_enum,
        page_size: Keyword.get(opts, :page_size, 0),
        page_token: Keyword.get(opts, :page_token, "")
      }

      fn channel, grpc_opts -> SchemaStub.list_schemas(channel, request, grpc_opts) end
      |> Request.execute(opts)
      |> Result.unwrap_list(:schemas, :next_page_token)
    end
  end

  @spec get_schema(String.t(), String.t(), keyword()) ::
          {:ok, PubsubGrpc.schema()} | {:error, Error.t()}
  def get_schema(project_id, schema_id, opts \\ []) do
    Telemetry.span(:get_schema, %{project_id: project_id, schema_id: schema_id}, fn ->
      do_get_schema(project_id, schema_id, opts)
    end)
  end

  defp do_get_schema(project_id, schema_id, opts) do
    view = opts[:view] || :full

    with {:ok, _} <- Validation.validate_project_id(project_id),
         {:ok, _} <- Validation.validate_schema_id(schema_id),
         {:ok, view_enum} <- Validation.validate_schema_view(view) do
      request = %PubsubV1.GetSchemaRequest{
        name: Request.schema_path(project_id, schema_id),
        view: view_enum
      }

      fn channel, grpc_opts -> SchemaStub.get_schema(channel, request, grpc_opts) end
      |> Request.execute(opts)
      |> Result.unwrap()
    end
  end

  @spec create_schema(String.t(), String.t(), :protocol_buffer | :avro, String.t(), keyword()) ::
          {:ok, PubsubGrpc.schema()} | {:error, Error.t()}
  def create_schema(project_id, schema_id, type, definition, opts \\ []) do
    Telemetry.span(
      :create_schema,
      %{project_id: project_id, schema_id: schema_id, schema_type: type},
      fn -> do_create_schema(project_id, schema_id, type, definition, opts) end
    )
  end

  defp do_create_schema(project_id, schema_id, type, definition, opts) do
    with {:ok, _} <- Validation.validate_project_id(project_id),
         {:ok, _} <- Validation.validate_schema_id(schema_id),
         {:ok, type_enum} <- Validation.validate_schema_type(type) do
      request = %PubsubV1.CreateSchemaRequest{
        parent: Request.project_path(project_id),
        schema_id: schema_id,
        schema: %PubsubV1.Schema{type: type_enum, definition: definition}
      }

      fn channel, grpc_opts -> SchemaStub.create_schema(channel, request, grpc_opts) end
      |> Request.execute(opts)
      |> Result.unwrap()
    end
  end

  @spec delete_schema(String.t(), String.t(), keyword()) :: :ok | {:error, Error.t()}
  def delete_schema(project_id, schema_id, opts \\ []) do
    Telemetry.span(:delete_schema, %{project_id: project_id, schema_id: schema_id}, fn ->
      do_delete_schema(project_id, schema_id, opts)
    end)
  end

  defp do_delete_schema(project_id, schema_id, opts) do
    with {:ok, _} <- Validation.validate_project_id(project_id),
         {:ok, _} <- Validation.validate_schema_id(schema_id) do
      request = %PubsubV1.DeleteSchemaRequest{name: Request.schema_path(project_id, schema_id)}

      fn channel, grpc_opts -> SchemaStub.delete_schema(channel, request, grpc_opts) end
      |> Request.execute(opts)
      |> Result.unwrap_empty()
    end
  end

  @spec validate_schema(String.t(), :protocol_buffer | :avro, String.t(), keyword()) ::
          {:ok, PubsubGrpc.validate_schema_response()} | {:error, Error.t()}
  def validate_schema(project_id, type, definition, opts \\ []) do
    Telemetry.span(:validate_schema, %{project_id: project_id, schema_type: type}, fn ->
      do_validate_schema(project_id, type, definition, opts)
    end)
  end

  defp do_validate_schema(project_id, type, definition, opts) do
    with {:ok, _} <- Validation.validate_project_id(project_id),
         {:ok, type_enum} <- Validation.validate_schema_type(type) do
      request = %PubsubV1.ValidateSchemaRequest{
        parent: Request.project_path(project_id),
        schema: %PubsubV1.Schema{type: type_enum, definition: definition}
      }

      fn channel, grpc_opts -> SchemaStub.validate_schema(channel, request, grpc_opts) end
      |> Request.execute(opts)
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
         {:ok, view_enum} <- Validation.validate_schema_view(view) do
      request = %PubsubV1.ListSchemaRevisionsRequest{
        name: Request.schema_path(project_id, schema_id),
        view: view_enum,
        page_size: Keyword.get(opts, :page_size, 0),
        page_token: Keyword.get(opts, :page_token, "")
      }

      fn channel, grpc_opts -> SchemaStub.list_schema_revisions(channel, request, grpc_opts) end
      |> Request.execute(opts)
      |> Result.unwrap_list(:schemas, :next_page_token)
    end
  end

  @spec validate_message(String.t(), String.t(), binary(), :json | :binary, keyword()) ::
          {:ok, PubsubGrpc.validate_message_response()} | {:error, Error.t()}
  def validate_message(project_id, schema_name, message, encoding, opts \\ []) do
    Telemetry.span(
      :validate_message,
      %{project_id: project_id, schema_name: schema_name, encoding: encoding},
      fn -> do_validate_message(project_id, schema_name, message, encoding, opts) end
    )
  end

  defp do_validate_message(project_id, schema_name, message, encoding, opts) do
    with {:ok, _} <- Validation.validate_project_id(project_id),
         {:ok, _} <- Validation.validate_schema_name(schema_name),
         {:ok, encoding_enum} <- Validation.validate_encoding(encoding) do
      # A bare schema ID is resolved within `project_id`.
      name =
        if String.contains?(schema_name, "/") do
          schema_name
        else
          Request.schema_path(project_id, schema_name)
        end

      request = %PubsubV1.ValidateMessageRequest{
        parent: Request.project_path(project_id),
        schema_spec: {:name, name},
        message: message,
        encoding: encoding_enum
      }

      fn channel, grpc_opts -> SchemaStub.validate_message(channel, request, grpc_opts) end
      |> Request.execute(opts)
      |> Result.unwrap()
    end
  end

  @spec validate_message_with_schema(
          String.t(),
          :protocol_buffer | :avro,
          String.t(),
          binary(),
          :json | :binary,
          keyword()
        ) ::
          {:ok, PubsubGrpc.validate_message_response()} | {:error, Error.t()}
  def validate_message_with_schema(project_id, type, definition, message, encoding, opts \\ []) do
    Telemetry.span(
      :validate_message_with_schema,
      %{project_id: project_id, schema_type: type, encoding: encoding},
      fn ->
        do_validate_message_with_schema(project_id, type, definition, message, encoding, opts)
      end
    )
  end

  defp do_validate_message_with_schema(project_id, type, definition, message, encoding, opts) do
    with {:ok, _} <- Validation.validate_project_id(project_id),
         {:ok, type_enum} <- Validation.validate_schema_type(type),
         {:ok, encoding_enum} <- Validation.validate_encoding(encoding) do
      request = %PubsubV1.ValidateMessageRequest{
        parent: Request.project_path(project_id),
        schema_spec: {:schema, %PubsubV1.Schema{type: type_enum, definition: definition}},
        message: message,
        encoding: encoding_enum
      }

      fn channel, grpc_opts -> SchemaStub.validate_message(channel, request, grpc_opts) end
      |> Request.execute(opts)
      |> Result.unwrap()
    end
  end
end
