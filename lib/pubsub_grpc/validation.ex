defmodule PubsubGrpc.Validation do
  @moduledoc false

  alias PubsubGrpc.Error

  @spec validate_project_id(term()) :: {:ok, String.t()} | {:error, Error.t()}
  def validate_project_id(project_id) when is_binary(project_id) and byte_size(project_id) > 0 do
    {:ok, project_id}
  end

  def validate_project_id(_) do
    {:error, Error.new(:validation_error, "project_id must be a non-empty string")}
  end

  # GCP Pub/Sub resource ID rules: start with a letter, 3-255 chars,
  # letters/digits/dashes/underscores/periods/tildes/plus/percent.
  # Names beginning with "goog" are reserved.
  @resource_id_regex ~r/^[A-Za-z][A-Za-z0-9\-_.~+%]{2,254}$/

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

  @spec validate_messages(term()) :: {:ok, [map()]} | {:error, Error.t()}
  def validate_messages([_ | _] = messages) when is_list(messages) do
    if Enum.all?(messages, &valid_message?/1) do
      {:ok, messages}
    else
      {:error,
       Error.new(
         :validation_error,
         "each message must be a map with non-empty :data (binary) or non-empty :attributes (map)"
       )}
    end
  end

  def validate_messages(_) do
    {:error, Error.new(:validation_error, "messages must be a non-empty list")}
  end

  @spec validate_ack_ids(term()) :: {:ok, [String.t()]} | {:error, Error.t()}
  def validate_ack_ids([_ | _] = ack_ids) when is_list(ack_ids) do
    if Enum.all?(ack_ids, &(is_binary(&1) and byte_size(&1) > 0)) do
      {:ok, ack_ids}
    else
      {:error, Error.new(:validation_error, "ack_ids must contain non-empty strings")}
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
  def validate_max_messages(n) when is_integer(n) and n > 0 do
    {:ok, n}
  end

  def validate_max_messages(_) do
    {:error, Error.new(:validation_error, "max_messages must be a positive integer")}
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

  defp valid_message?(%{data: data, attributes: attrs})
       when is_binary(data) and is_map(attrs) do
    byte_size(data) > 0 or map_size(attrs) > 0
  end

  defp valid_message?(%{data: data}) when is_binary(data) and byte_size(data) > 0, do: true

  defp valid_message?(%{attributes: attrs}) when is_map(attrs) and map_size(attrs) > 0, do: true

  defp valid_message?(_), do: false
end
