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

  @spec validate_topic_id(term()) :: {:ok, String.t()} | {:error, Error.t()}
  def validate_topic_id(topic_id) when is_binary(topic_id) and byte_size(topic_id) > 0 do
    {:ok, topic_id}
  end

  def validate_topic_id(_) do
    {:error, Error.new(:validation_error, "topic_id must be a non-empty string")}
  end

  @spec validate_subscription_id(term()) :: {:ok, String.t()} | {:error, Error.t()}
  def validate_subscription_id(sub_id) when is_binary(sub_id) and byte_size(sub_id) > 0 do
    {:ok, sub_id}
  end

  def validate_subscription_id(_) do
    {:error, Error.new(:validation_error, "subscription_id must be a non-empty string")}
  end

  @spec validate_schema_id(term()) :: {:ok, String.t()} | {:error, Error.t()}
  def validate_schema_id(schema_id) when is_binary(schema_id) and byte_size(schema_id) > 0 do
    {:ok, schema_id}
  end

  def validate_schema_id(_) do
    {:error, Error.new(:validation_error, "schema_id must be a non-empty string")}
  end

  @spec validate_messages(term()) :: {:ok, [map()]} | {:error, Error.t()}
  def validate_messages([_ | _] = messages) when is_list(messages) do
    if Enum.all?(messages, &valid_message?/1) do
      {:ok, messages}
    else
      {:error,
       Error.new(
         :validation_error,
         "each message must be a map with :data (binary) and/or :attributes (map)"
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

  defp valid_message?(%{data: data}) when is_binary(data), do: true
  defp valid_message?(%{attributes: attrs}) when is_map(attrs) and map_size(attrs) > 0, do: true
  defp valid_message?(_), do: false
end
