defmodule PubsubGrpc.Validation do
  @moduledoc false

  alias PubsubGrpc.Error
  alias PubsubGrpc.Proto.Google.Pubsub.V1.PubsubMessage

  # Request limits. Byte limits use the larger reading of "MB"/"KB" (MiB/KiB) and
  # count only payload bytes, so a request rejected here is always over the
  # service limit; the service still enforces the exact limits.
  #
  # https://cloud.google.com/pubsub/quotas#resource_limits (fetched 2026-10-06):
  #   "Publish request: 10MB (total size), 1,000 messages"
  @max_publish_messages 1_000
  @max_publish_bytes 10 * 1024 * 1024
  #   "Acknowledge and ModifyAckDeadline requests: 512 KB (total size)"
  #   (no ack-id count limit is documented)
  @max_ack_request_bytes 512 * 1024
  # PullRequest.max_messages is an int32
  # (https://cloud.google.com/pubsub/docs/reference/rpc/google.pubsub.v1#pullrequest).
  # The documented cap of 1,000 applies to the Pull *response*, not the request.
  @max_int32 2_147_483_647

  @spec max_publish_messages() :: pos_integer()
  def max_publish_messages, do: @max_publish_messages

  @spec max_publish_bytes() :: pos_integer()
  def max_publish_bytes, do: @max_publish_bytes

  @spec max_ack_request_bytes() :: pos_integer()
  def max_ack_request_bytes, do: @max_ack_request_bytes

  # Project IDs (https://cloud.google.com/resource-manager/docs/creating-managing-projects):
  # 6-30 chars, lowercase letters/digits/hyphens, starts with a letter, does not
  # end with a hyphen. Also accepted: project numbers (Google APIs accept them in
  # place of IDs, AIP-2510) and legacy domain-scoped IDs (`example.com:my-project`).
  @project_id_regex ~r/\A[a-z][a-z0-9-]{4,28}[a-z0-9]\z/
  @project_number_regex ~r/\A[0-9]{1,19}\z/
  @domain_scoped_regex ~r/\A[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+:[a-z][a-z0-9-]*[a-z0-9]\z/

  @spec validate_project_id(term()) :: {:ok, String.t()} | {:error, Error.t()}
  def validate_project_id(project_id) when is_binary(project_id) do
    if Regex.match?(@project_id_regex, project_id) or
         Regex.match?(@project_number_regex, project_id) or
         Regex.match?(@domain_scoped_regex, project_id) do
      {:ok, project_id}
    else
      {:error,
       Error.new(
         :validation_error,
         "project_id must be a project ID (6-30 lowercase letters, digits or hyphens, " <>
           "starting with a letter and not ending with a hyphen), a project number, " <>
           "or a domain-scoped ID (example.com:my-project)"
       )}
    end
  end

  def validate_project_id(_) do
    {:error, Error.new(:validation_error, "project_id must be a string")}
  end

  # GCP Pub/Sub resource ID rules: start with a letter, 3-255 chars,
  # letters/digits/dashes/underscores/periods/tildes/plus/percent.
  # Names beginning with "goog" are reserved.
  @resource_id_regex ~r/\A[A-Za-z][A-Za-z0-9\-_.~+%]{2,254}\z/

  @spec validate_topic_id(term()) :: {:ok, String.t()} | {:error, Error.t()}
  def validate_topic_id(topic_id) do
    validate_resource_id(topic_id, "topic_id")
  end

  @spec validate_subscription_id(term()) :: {:ok, String.t()} | {:error, Error.t()}
  def validate_subscription_id(sub_id) do
    validate_resource_id(sub_id, "subscription_id")
  end

  @spec validate_schema_id(term()) :: {:ok, String.t()} | {:error, Error.t()}
  def validate_schema_id(schema_id) do
    validate_resource_id(schema_id, "schema_id")
  end

  @doc """
  A schema ID, or a full schema name `projects/<project>/schemas/<schema_id>`.
  """
  @spec validate_schema_name(term()) :: {:ok, String.t()} | {:error, Error.t()}
  def validate_schema_name(name) when is_binary(name) do
    case String.split(name, "/") do
      [schema_id] ->
        validate_schema_id(schema_id)

      ["projects", project, "schemas", schema_id] ->
        with {:ok, _} <- validate_project_id(project),
             {:ok, _} <- validate_schema_id(schema_id) do
          {:ok, name}
        end

      _ ->
        {:error,
         Error.new(
           :validation_error,
           "schema_name must be a schema ID or projects/<project>/schemas/<schema_id>"
         )}
    end
  end

  def validate_schema_name(_) do
    {:error, Error.new(:validation_error, "schema_name must be a string")}
  end

  defp validate_resource_id(id, field) when is_binary(id) do
    cond do
      not Regex.match?(@resource_id_regex, id) ->
        {:error,
         Error.new(
           :validation_error,
           "#{field} must start with a letter and be 3-255 chars of " <>
             "letters/digits/-_.~+%"
         )}

      String.starts_with?(id, "goog") ->
        {:error,
         Error.new(:validation_error, "#{field} must not begin with reserved prefix 'goog'")}

      true ->
        {:ok, id}
    end
  end

  defp validate_resource_id(_, field) do
    {:error, Error.new(:validation_error, "#{field} must be a string")}
  end

  @doc """
  Validates messages for a publish request and builds the `PubsubMessage`
  structs in a single pass, enforcing the message-count and size limits.
  """
  @spec build_publish_messages(term()) ::
          {:ok, [PubsubMessage.t()], pos_integer()} | {:error, Error.t()}
  def build_publish_messages([_ | _] = messages) do
    messages
    |> Enum.reduce_while({[], 0, 0}, fn message, {acc, count, bytes} ->
      with {:ok, data, attributes} <- message_fields(message),
           :ok <- check_publish_count(count + 1),
           bytes = bytes + byte_size(data) + attributes_bytes(attributes),
           :ok <- check_publish_bytes(bytes) do
        struct = %PubsubMessage{data: data, attributes: attributes}
        {:cont, {[struct | acc], count + 1, bytes}}
      else
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:error, _} = error -> error
      {acc, count, _bytes} -> {:ok, Enum.reverse(acc), count}
    end
  end

  def build_publish_messages(_) do
    {:error, Error.new(:validation_error, "messages must be a non-empty list")}
  end

  @spec validate_ack_ids(term()) :: {:ok, [String.t()]} | {:error, Error.t()}
  def validate_ack_ids([_ | _] = ack_ids) do
    Enum.reduce_while(ack_ids, 0, fn
      ack_id, bytes when is_binary(ack_id) and byte_size(ack_id) > 0 ->
        bytes = bytes + byte_size(ack_id)

        if bytes > @max_ack_request_bytes do
          {:halt,
           {:error,
            Error.new(
              :validation_error,
              "ack_ids exceed the #{@max_ack_request_bytes}-byte request size limit; " <>
                "split them into several requests"
            )}}
        else
          {:cont, bytes}
        end

      _, _ ->
        {:halt, {:error, Error.new(:validation_error, "ack_ids must contain non-empty strings")}}
    end)
    |> case do
      {:error, _} = error -> error
      _bytes -> {:ok, ack_ids}
    end
  end

  def validate_ack_ids(_) do
    {:error, Error.new(:validation_error, "ack_ids must be a non-empty list")}
  end

  @spec validate_ack_deadline(term()) :: {:ok, integer()} | {:error, Error.t()}
  def validate_ack_deadline(seconds)
      when is_integer(seconds) and seconds >= 10 and seconds <= 600 do
    {:ok, seconds}
  end

  def validate_ack_deadline(_) do
    {:error,
     Error.new(:validation_error, "ack_deadline_seconds must be an integer between 10 and 600")}
  end

  @spec validate_ack_deadline_with_zero(term()) :: {:ok, integer()} | {:error, Error.t()}
  def validate_ack_deadline_with_zero(seconds)
      when is_integer(seconds) and seconds >= 0 and seconds <= 600 do
    {:ok, seconds}
  end

  def validate_ack_deadline_with_zero(_) do
    {:error,
     Error.new(:validation_error, "ack_deadline_seconds must be an integer between 0 and 600")}
  end

  @spec validate_max_messages(term()) :: {:ok, integer()} | {:error, Error.t()}
  def validate_max_messages(n) when is_integer(n) and n > 0 and n <= @max_int32 do
    {:ok, n}
  end

  def validate_max_messages(_) do
    {:error,
     Error.new(
       :validation_error,
       "max_messages must be a positive integer of at most #{@max_int32}"
     )}
  end

  @spec validate_schema_type(term()) :: {:ok, atom()} | {:error, Error.t()}
  def validate_schema_type(:protocol_buffer), do: {:ok, :PROTOCOL_BUFFER}
  def validate_schema_type(:avro), do: {:ok, :AVRO}

  def validate_schema_type(_) do
    {:error, Error.new(:validation_error, "schema type must be :protocol_buffer or :avro")}
  end

  @spec validate_schema_view(term()) :: {:ok, atom()} | {:error, Error.t()}
  def validate_schema_view(:basic), do: {:ok, :BASIC}
  def validate_schema_view(:full), do: {:ok, :FULL}

  def validate_schema_view(_) do
    {:error, Error.new(:validation_error, "schema view must be :basic or :full")}
  end

  @spec validate_encoding(term()) :: {:ok, atom()} | {:error, Error.t()}
  def validate_encoding(:json), do: {:ok, :JSON}
  def validate_encoding(:binary), do: {:ok, :BINARY}

  def validate_encoding(_) do
    {:error, Error.new(:validation_error, "encoding must be :json or :binary")}
  end

  # Private

  # A message needs non-empty :data (binary) or non-empty :attributes (map).
  defp message_fields(%{} = message) do
    data = Map.get(message, :data, "")
    attributes = Map.get(message, :attributes, %{})

    if is_binary(data) and is_map(attributes) and
         (byte_size(data) > 0 or map_size(attributes) > 0) do
      {:ok, data, attributes}
    else
      invalid_message()
    end
  end

  defp message_fields(_), do: invalid_message()

  defp invalid_message do
    {:error,
     Error.new(
       :validation_error,
       "each message must be a map with non-empty :data (binary) or non-empty :attributes (map)"
     )}
  end

  defp attributes_bytes(attributes) do
    Enum.reduce(attributes, 0, fn {key, value}, acc ->
      acc + term_bytes(key) + term_bytes(value)
    end)
  end

  defp term_bytes(term) when is_binary(term), do: byte_size(term)
  defp term_bytes(_term), do: 0

  defp check_publish_count(count) when count > @max_publish_messages do
    {:error,
     Error.new(
       :validation_error,
       "a publish request can contain at most #{@max_publish_messages} messages; " <>
         "split them into several requests"
     )}
  end

  defp check_publish_count(_count), do: :ok

  defp check_publish_bytes(bytes) when bytes > @max_publish_bytes do
    {:error,
     Error.new(
       :validation_error,
       "messages exceed the #{@max_publish_bytes}-byte publish request size limit " <>
         "(data plus attribute keys and values); split them into several requests"
     )}
  end

  defp check_publish_bytes(_bytes), do: :ok
end
