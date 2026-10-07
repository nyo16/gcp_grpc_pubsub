defmodule PubsubGrpc.SchemaIntegrationTest do
  @moduledoc """
  Schema API against the emulator.

  The emulator only implements Avro schemas, so the flows below use Avro.
  """
  use ExUnit.Case, async: true

  import PubsubGrpc.EmulatorHelper,
    only: [unique_name: 1, track_schema: 1, schema_path: 1, list_all: 2]

  alias PubsubGrpc.Error
  alias PubsubGrpc.Proto.Google.Pubsub.V1, as: PubsubV1

  @moduletag :integration

  @project "test-project-id"

  @avro ~s({"type":"record","name":"Msg","fields":[{"name":"name","type":"string"}]})
  @json_message ~s({"name":"hi"})
  # Avro binary encoding of %{"name" => "hi"}: zigzag varint length 2 (=4), then the bytes.
  @binary_message <<4, "hi">>

  setup do
    %{schema_id: track_schema(unique_name("test-schema"))}
  end

  test "schema lifecycle: create, read, validate, delete", %{schema_id: schema_id} do
    name = schema_path(schema_id)

    assert {:ok, %PubsubV1.Schema{name: ^name, type: :AVRO, definition: @avro}} =
             PubsubGrpc.create_schema(@project, schema_id, :avro, @avro)

    assert {:ok, %PubsubV1.Schema{name: ^name, type: :AVRO, definition: @avro} = schema} =
             PubsubGrpc.get_schema(@project, schema_id)

    assert {:ok, %{schemas: _, next_page_token: _}} = PubsubGrpc.list_schemas(@project)
    assert name in Enum.map(list_all(:schemas, &PubsubGrpc.list_schemas(@project, &1)), & &1.name)

    assert {:ok, %{schemas: [%PubsubV1.Schema{name: ^name, revision_id: revision_id}]}} =
             PubsubGrpc.list_schema_revisions(@project, schema_id)

    assert revision_id == schema.revision_id

    assert {:ok, %PubsubV1.ValidateMessageResponse{}} =
             PubsubGrpc.validate_message(@project, schema_id, @json_message, :json)

    assert {:ok, %PubsubV1.ValidateMessageResponse{}} =
             PubsubGrpc.validate_message(@project, schema_id, @binary_message, :binary)

    assert {:ok, %PubsubV1.ValidateMessageResponse{}} =
             PubsubGrpc.validate_message(@project, name, @json_message, :json)

    assert {:error, %Error{code: :invalid_argument}} =
             PubsubGrpc.validate_message(@project, schema_id, ~s({"other":1}), :json)

    assert :ok = PubsubGrpc.delete_schema(@project, schema_id)
    assert {:error, %Error{code: :not_found}} = PubsubGrpc.get_schema(@project, schema_id)
  end

  test "Schema module functions match the facade", %{schema_id: schema_id} do
    assert {:ok, %PubsubV1.Schema{}} =
             PubsubGrpc.Schema.create_schema(@project, schema_id, :avro, @avro)

    assert {:ok, %PubsubV1.Schema{definition: @avro}} =
             PubsubGrpc.Schema.get_schema(@project, schema_id)
  end

  test "create_schema rejects a duplicate ID", %{schema_id: schema_id} do
    assert {:ok, _} = PubsubGrpc.create_schema(@project, schema_id, :avro, @avro)

    assert {:error, %Error{code: :already_exists}} =
             PubsubGrpc.create_schema(@project, schema_id, :avro, @avro)
  end

  test "validate_schema accepts valid Avro and rejects a broken definition" do
    assert {:ok, %PubsubV1.ValidateSchemaResponse{}} =
             PubsubGrpc.validate_schema(@project, :avro, @avro)

    assert {:error, %Error{code: :invalid_argument}} =
             PubsubGrpc.validate_schema(@project, :avro, ~s({"type":"record"))
  end

  test "validate_message_with_schema validates against an inline definition" do
    assert {:ok, %PubsubV1.ValidateMessageResponse{}} =
             PubsubGrpc.validate_message_with_schema(@project, :avro, @avro, @json_message, :json)

    assert {:ok, %PubsubV1.ValidateMessageResponse{}} =
             PubsubGrpc.validate_message_with_schema(
               @project,
               :avro,
               @avro,
               @binary_message,
               :binary
             )

    assert {:error, %Error{code: :invalid_argument}} =
             PubsubGrpc.validate_message_with_schema(@project, :avro, @avro, "not json", :json)
  end

  test "operations on a missing schema return :not_found" do
    missing = unique_name("missing-schema")

    assert {:error, %Error{code: :not_found}} = PubsubGrpc.get_schema(@project, missing)
    assert {:error, %Error{code: :not_found}} = PubsubGrpc.delete_schema(@project, missing)

    assert {:error, %Error{code: :not_found}} =
             PubsubGrpc.validate_message(@project, missing, @json_message, :json)
  end

  test "protocol_buffer schemas are rejected by the emulator", %{schema_id: schema_id} do
    # EMULATOR LIMITATION, not library behaviour: the emulator's schema backend
    # only implements Avro and answers UNIMPLEMENTED ("Protocol buffer support
    # not implemented in emulator") for PROTOCOL_BUFFER. Against real Pub/Sub
    # this call succeeds. This test pins that the request reaches the server
    # with the right type and that the status maps to :unimplemented.
    definition = "syntax = \"proto3\"; message Msg { string name = 1; }"

    assert {:error, %Error{code: :unimplemented}} =
             PubsubGrpc.create_schema(@project, schema_id, :protocol_buffer, definition)
  end
end
