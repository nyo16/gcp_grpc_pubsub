defmodule PubsubGrpc.Schema do
  @moduledoc """
  Schema management for Google Cloud Pub/Sub.

  This module provides functions for managing Pub/Sub schemas, which define the
  structure and format of messages published to topics. Schemas support both
  Protocol Buffer and Avro formats.

  ## Schema Features

  - Create and manage schema definitions
  - List schemas in a project
  - Get schema details with different view levels
  - Manage schema revisions
  - Validate messages against schemas
  - Support for Protocol Buffer and Avro formats

  ## Examples

      # List schemas
      {:ok, schemas_info} = PubsubGrpc.Schema.list_schemas("my-project")

      # Get specific schema
      {:ok, schema} = PubsubGrpc.Schema.get_schema("my-project", "my-schema")

      # Create Protocol Buffer schema
      definition = '''
      syntax = "proto3";

      message Person {
        string name = 1;
        int32 age = 2;
      }
      '''

      {:ok, schema} = PubsubGrpc.Schema.create_schema(
        "my-project",
        "person-schema",
        :protocol_buffer,
        definition
      )

  """

  alias PubsubGrpc.Client

  @doc """
  Lists schemas in a project.

  ## Parameters
  - `project_id`: The Google Cloud project ID
  - `opts`: Optional parameters
    - `:view` - Schema view level (`:basic` or `:full`, default: `:basic`)
    - `:page_size` - Maximum number of schemas to return
    - `:page_token` - Token for pagination

  ## Returns
  - `{:ok, %{schemas: schemas, next_page_token: token}}` - List of schemas
  - `{:error, reason}` - Error listing schemas

  ## Examples

      # List all schemas (basic view)
      {:ok, result} = PubsubGrpc.Schema.list_schemas("my-project")
      IO.inspect(result.schemas)

      # List with full details
      {:ok, result} = PubsubGrpc.Schema.list_schemas("my-project", view: :full)

      # List with pagination
      {:ok, result} = PubsubGrpc.Schema.list_schemas("my-project",
        page_size: 10,
        page_token: "next_page_token"
      )

  """
  @spec list_schemas(String.t(), keyword()) :: {:ok, map()} | {:error, any()}
  def list_schemas(project_id, opts \\ []) do
    project_path = "projects/#{project_id}"
    view = schema_view_atom_to_enum(opts[:view] || :basic)

    operation = fn channel ->
      request = %Google.Pubsub.V1.ListSchemasRequest{
        parent: project_path,
        view: view,
        page_size: Keyword.get(opts, :page_size, 0),
        page_token: Keyword.get(opts, :page_token, "")
      }

      auth_opts = PubsubGrpc.Auth.request_opts()
      Google.Pubsub.V1.SchemaService.Stub.list_schemas(channel, request, auth_opts)
    end

    case Client.execute(operation) do
      {:ok, {:ok, response}} ->
        {:ok, %{schemas: response.schemas, next_page_token: response.next_page_token}}

      {:ok, {:error, error}} -> {:error, error}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Gets details of a specific schema.

  ## Parameters
  - `project_id`: The Google Cloud project ID
  - `schema_id`: The schema identifier
  - `opts`: Optional parameters
    - `:view` - Schema view level (`:basic` or `:full`, default: `:full`)

  ## Returns
  - `{:ok, schema}` - Schema details
  - `{:error, reason}` - Error getting schema

  ## Examples

      # Get schema with full details
      {:ok, schema} = PubsubGrpc.Schema.get_schema("my-project", "my-schema")
      IO.puts("Schema type: \#{schema.type}")
      IO.puts("Definition: \#{schema.definition}")

      # Get schema with basic details only
      {:ok, schema} = PubsubGrpc.Schema.get_schema("my-project", "my-schema", view: :basic)

  """
  @spec get_schema(String.t(), String.t(), keyword()) :: {:ok, Google.Pubsub.V1.Schema.t()} | {:error, any()}
  def get_schema(project_id, schema_id, opts \\ []) do
    schema_path = schema_path(project_id, schema_id)
    view = schema_view_atom_to_enum(opts[:view] || :full)

    operation = fn channel ->
      request = %Google.Pubsub.V1.GetSchemaRequest{
        name: schema_path,
        view: view
      }

      auth_opts = PubsubGrpc.Auth.request_opts()
      Google.Pubsub.V1.SchemaService.Stub.get_schema(channel, request, auth_opts)
    end

    case Client.execute(operation) do
      {:ok, {:ok, result}} -> {:ok, result}
      {:ok, {:error, error}} -> {:error, error}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Creates a new schema.

  ## Parameters
  - `project_id`: The Google Cloud project ID
  - `schema_id`: The schema identifier
  - `type`: Schema type (`:protocol_buffer` or `:avro`)
  - `definition`: The schema definition string

  ## Returns
  - `{:ok, schema}` - Created schema
  - `{:error, reason}` - Error creating schema

  ## Examples

      # Create Protocol Buffer schema
      protobuf_definition = '''
      syntax = "proto3";

      message UserEvent {
        string user_id = 1;
        string event_type = 2;
        int64 timestamp = 3;
      }
      '''

      {:ok, schema} = PubsubGrpc.Schema.create_schema(
        "my-project",
        "user-event-schema",
        :protocol_buffer,
        protobuf_definition
      )

      # Create Avro schema
      avro_definition = '''
      {
        "type": "record",
        "name": "UserEvent",
        "fields": [
          {"name": "user_id", "type": "string"},
          {"name": "event_type", "type": "string"},
          {"name": "timestamp", "type": "long"}
        ]
      }
      '''

      {:ok, schema} = PubsubGrpc.Schema.create_schema(
        "my-project",
        "user-event-avro-schema",
        :avro,
        avro_definition
      )

  """
  @spec create_schema(String.t(), String.t(), :protocol_buffer | :avro, String.t()) :: {:ok, Google.Pubsub.V1.Schema.t()} | {:error, any()}
  def create_schema(project_id, schema_id, type, definition) do
    project_path = "projects/#{project_id}"
    schema_type = schema_type_atom_to_enum(type)

    operation = fn channel ->
      schema = %Google.Pubsub.V1.Schema{
        type: schema_type,
        definition: definition
      }

      request = %Google.Pubsub.V1.CreateSchemaRequest{
        parent: project_path,
        schema_id: schema_id,
        schema: schema
      }

      auth_opts = PubsubGrpc.Auth.request_opts()
      Google.Pubsub.V1.SchemaService.Stub.create_schema(channel, request, auth_opts)
    end

    case Client.execute(operation) do
      {:ok, {:ok, result}} -> {:ok, result}
      {:ok, {:error, error}} -> {:error, error}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Deletes a schema.

  ## Parameters
  - `project_id`: The Google Cloud project ID
  - `schema_id`: The schema identifier

  ## Returns
  - `:ok` - Successfully deleted schema
  - `{:error, reason}` - Error deleting schema

  ## Examples

      :ok = PubsubGrpc.Schema.delete_schema("my-project", "old-schema")

  """
  @spec delete_schema(String.t(), String.t()) :: :ok | {:error, any()}
  def delete_schema(project_id, schema_id) do
    schema_path = schema_path(project_id, schema_id)

    operation = fn channel ->
      request = %Google.Pubsub.V1.DeleteSchemaRequest{name: schema_path}
      auth_opts = PubsubGrpc.Auth.request_opts()
      Google.Pubsub.V1.SchemaService.Stub.delete_schema(channel, request, auth_opts)
    end

    case Client.execute(operation) do
      {:ok, {:ok, %Google.Protobuf.Empty{}}} -> :ok
      {:ok, {:error, error}} -> {:error, error}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Lists revisions of a schema.

  ## Parameters
  - `project_id`: The Google Cloud project ID
  - `schema_id`: The schema identifier
  - `opts`: Optional parameters
    - `:view` - Schema view level (`:basic` or `:full`, default: `:basic`)
    - `:page_size` - Maximum number of revisions to return
    - `:page_token` - Token for pagination

  ## Returns
  - `{:ok, %{schemas: schema_revisions, next_page_token: token}}` - List of schema revisions
  - `{:error, reason}` - Error listing schema revisions

  ## Examples

      {:ok, result} = PubsubGrpc.Schema.list_schema_revisions("my-project", "my-schema")
      IO.inspect(result.schemas)  # List of schema revision objects

  """
  @spec list_schema_revisions(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, any()}
  def list_schema_revisions(project_id, schema_id, opts \\ []) do
    schema_path = schema_path(project_id, schema_id)
    view = schema_view_atom_to_enum(opts[:view] || :basic)

    operation = fn channel ->
      request = %Google.Pubsub.V1.ListSchemaRevisionsRequest{
        name: schema_path,
        view: view,
        page_size: Keyword.get(opts, :page_size, 0),
        page_token: Keyword.get(opts, :page_token, "")
      }

      auth_opts = PubsubGrpc.Auth.request_opts()
      Google.Pubsub.V1.SchemaService.Stub.list_schema_revisions(channel, request, auth_opts)
    end

    case Client.execute(operation) do
      {:ok, {:ok, response}} ->
        {:ok, %{schemas: response.schemas, next_page_token: response.next_page_token}}

      {:ok, {:error, error}} -> {:error, error}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Validates a schema definition.

  ## Parameters
  - `project_id`: The Google Cloud project ID
  - `type`: Schema type (`:protocol_buffer` or `:avro`)
  - `definition`: The schema definition string

  ## Returns
  - `{:ok, validation_result}` - Validation successful
  - `{:error, reason}` - Validation error

  ## Examples

      protobuf_def = '''
      syntax = "proto3";
      message User { string name = 1; }
      '''

      {:ok, result} = PubsubGrpc.Schema.validate_schema(
        "my-project",
        :protocol_buffer,
        protobuf_def
      )

  """
  @spec validate_schema(String.t(), :protocol_buffer | :avro, String.t()) :: {:ok, any()} | {:error, any()}
  def validate_schema(project_id, type, definition) do
    project_path = "projects/#{project_id}"
    schema_type = schema_type_atom_to_enum(type)

    operation = fn channel ->
      schema = %Google.Pubsub.V1.Schema{
        type: schema_type,
        definition: definition
      }

      request = %Google.Pubsub.V1.ValidateSchemaRequest{
        parent: project_path,
        schema: schema
      }

      auth_opts = PubsubGrpc.Auth.request_opts()
      Google.Pubsub.V1.SchemaService.Stub.validate_schema(channel, request, auth_opts)
    end

    case Client.execute(operation) do
      {:ok, {:ok, result}} -> {:ok, result}
      {:ok, {:error, error}} -> {:error, error}
      {:error, reason} -> {:error, reason}
    end
  end

  # TODO: Add validate_message function
  # Note: ValidateMessageRequest uses oneof fields which need special handling

  # Private helper functions

  defp schema_path(project_id, schema_id) do
    "projects/#{project_id}/schemas/#{schema_id}"
  end

  defp schema_view_atom_to_enum(:basic), do: :BASIC
  defp schema_view_atom_to_enum(:full), do: :FULL
  defp schema_view_atom_to_enum(_), do: :BASIC

  defp schema_type_atom_to_enum(:protocol_buffer), do: :PROTOCOL_BUFFER
  defp schema_type_atom_to_enum(:avro), do: :AVRO
  defp schema_type_atom_to_enum(_), do: :PROTOCOL_BUFFER

  # defp encoding_atom_to_enum(:json), do: :JSON
  # defp encoding_atom_to_enum(:binary), do: :BINARY
  # defp encoding_atom_to_enum(_), do: :JSON
end
