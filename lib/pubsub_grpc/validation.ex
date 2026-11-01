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
  #
  # IDs are checked with binary matchers, not regexes: on OTP 28+ a regex held in
  # a module attribute is re-imported (`:re.import/1`) on every evaluation, and
  # these checks run on every request.
  defguardp is_lower(c) when c in ?a..?z
  defguardp is_digit(c) when c in ?0..?9
  defguardp is_lower_alnum(c) when is_lower(c) or is_digit(c)
  defguardp is_lower_alnum_dash(c) when is_lower_alnum(c) or c == ?-

  defguardp is_resource_char(c)
            when c in ?a..?z or c in ?A..?Z or is_digit(c) or c in [?-, ?_, ?., ?~, ?+, ?%]

  @spec validate_project_id(term()) :: {:ok, String.t()} | {:error, Error.t()}
  def validate_project_id(project_id) when is_binary(project_id) do
    if project_id?(project_id) or project_number?(project_id) or
         domain_scoped_project_id?(project_id) do
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
      not resource_id?(id) ->
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

  # `[a-z][a-z0-9-]{4,28}[a-z0-9]`
  defp project_id?(<<first, rest::binary>> = id)
       when is_lower(first) and byte_size(id) >= 6 and byte_size(id) <= 30,
       do: lower_alnum_dash?(rest) and is_lower_alnum(:binary.last(id))

  defp project_id?(_id), do: false

  # `[0-9]{1,19}`
  defp project_number?(id) when byte_size(id) >= 1 and byte_size(id) <= 19, do: digits?(id)
  defp project_number?(_id), do: false

  # `<domain>:<project>`: at least two dot-separated DNS labels, then
  # `[a-z][a-z0-9-]*[a-z0-9]`.
  defp domain_scoped_project_id?(id) do
    with [domain, project] <- :binary.split(id, ":"),
         [_, _ | _] = labels <- :binary.split(domain, ".", [:global]),
         true <- Enum.all?(labels, &dns_label?/1),
         <<first, _::binary>> when is_lower(first) and byte_size(project) >= 2 <- project do
      lower_alnum_dash?(project) and is_lower_alnum(:binary.last(project))
    else
      _ -> false
    end
  end

  # `[a-z0-9]([a-z0-9-]*[a-z0-9])?`
  defp dns_label?(<<first, _::binary>> = label) when is_lower_alnum(first),
    do: lower_alnum_dash?(label) and is_lower_alnum(:binary.last(label))

  defp dns_label?(_label), do: false

  # `[A-Za-z][A-Za-z0-9\-_.~+%]{2,254}`
  defp resource_id?(<<first, rest::binary>> = id)
       when (first in ?a..?z or first in ?A..?Z) and byte_size(id) >= 3 and byte_size(id) <= 255,
       do: resource_chars?(rest)

  defp resource_id?(_id), do: false

  defp lower_alnum_dash?(<<c, rest::binary>>) when is_lower_alnum_dash(c),
    do: lower_alnum_dash?(rest)

  defp lower_alnum_dash?(<<>>), do: true
  defp lower_alnum_dash?(_), do: false

  defp digits?(<<c, rest::binary>>) when is_digit(c), do: digits?(rest)
  defp digits?(<<>>), do: true
  defp digits?(_), do: false

  defp resource_chars?(<<c, rest::binary>>) when is_resource_char(c), do: resource_chars?(rest)
  defp resource_chars?(<<>>), do: true
  defp resource_chars?(_), do: false

  @doc """
  Validates messages for a publish request and builds the `PubsubMessage`
  structs in a single pass, enforcing the message-count and size limits. Never
  raises, including on improper lists.
  """
  @spec build_publish_messages(term()) ::
          {:ok, [PubsubMessage.t()], pos_integer()} | {:error, Error.t()}
  def build_publish_messages([_ | _] = messages), do: build_messages(messages, [], 0, 0)

  def build_publish_messages(_) do
    {:error, Error.new(:validation_error, "messages must be a non-empty list")}
  end

  defp build_messages([], acc, count, _bytes), do: {:ok, Enum.reverse(acc), count}

  defp build_messages([message | rest], acc, count, bytes) do
    with {:ok, data, attributes} <- message_fields(message),
         :ok <- check_publish_count(count + 1),
         {:ok, attributes_bytes} <- attributes_bytes(attributes),
         bytes = bytes + byte_size(data) + attributes_bytes,
         :ok <- check_publish_bytes(bytes) do
      message = %PubsubMessage{data: data, attributes: attributes}
      build_messages(rest, [message | acc], count + 1, bytes)
    end
  end

  defp build_messages(_improper_tail, _acc, _count, _bytes) do
    {:error, Error.new(:validation_error, "messages must be a non-empty list")}
  end

  @doc """
  The length of a proper list; `0` for anything else (including improper lists).
  """
  @spec list_length(term()) :: non_neg_integer()
  def list_length(list), do: list_length(list, 0)

  defp list_length([_ | rest], count), do: list_length(rest, count + 1)
  defp list_length([], count), do: count
  defp list_length(_other, _count), do: 0

  @doc """
  Validates ack IDs in a single pass and returns their count. Never raises,
  including on improper lists.
  """
  @spec validate_ack_ids(term()) :: {:ok, pos_integer()} | {:error, Error.t()}
  def validate_ack_ids([_ | _] = ack_ids), do: check_ack_ids(ack_ids, 0, 0)

  def validate_ack_ids(_) do
    {:error, Error.new(:validation_error, "ack_ids must be a non-empty list")}
  end

  defp check_ack_ids([], count, _bytes), do: {:ok, count}

  defp check_ack_ids([ack_id | rest], count, bytes)
       when is_binary(ack_id) and byte_size(ack_id) > 0 do
    bytes = bytes + byte_size(ack_id)

    if bytes > @max_ack_request_bytes do
      {:error,
       Error.new(
         :validation_error,
         "ack_ids exceed the #{@max_ack_request_bytes}-byte request size limit; " <>
           "split them into several requests"
       )}
    else
      check_ack_ids(rest, count + 1, bytes)
    end
  end

  # A non-string element, an empty string, or an improper tail.
  defp check_ack_ids(_rest, _count, _bytes) do
    {:error, Error.new(:validation_error, "ack_ids must be a list of non-empty strings")}
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

  @doc """
  Validates a per-call `opts` keyword list: every key must be in `allowed_keys`,
  and the values of the known options must be well-typed. Runs before pool
  checkout, so a bad option never reaches the gRPC layer.

  Duplicate keys are allowed (the first one wins, as with `Keyword.get/2`), so
  `[timeout: t] ++ opts` keeps working; `Keyword.validate/2` would reject them.
  """
  @spec validate_request_opts(term(), [atom()]) :: {:ok, keyword()} | {:error, Error.t()}
  def validate_request_opts(opts, allowed_keys) when is_list(opts) do
    cond do
      not Keyword.keyword?(opts) ->
        {:error, Error.new(:validation_error, "opts must be a keyword list")}

      (unknown = unknown_keys(opts, allowed_keys)) != [] ->
        {:error,
         Error.new(
           :validation_error,
           "unknown option(s) #{inspect(unknown)}; accepted: #{inspect(allowed_keys)}"
         )}

      true ->
        validate_opt_values(opts)
    end
  end

  def validate_request_opts(_opts, _allowed_keys) do
    {:error, Error.new(:validation_error, "opts must be a keyword list")}
  end

  @spec validate_timeout(term()) :: {:ok, timeout()} | {:error, Error.t()}
  def validate_timeout(timeout) when is_integer(timeout) and timeout > 0, do: {:ok, timeout}
  def validate_timeout(:infinity), do: {:ok, :infinity}

  def validate_timeout(_) do
    {:error,
     Error.new(
       :validation_error,
       "timeout must be a positive integer (milliseconds) or :infinity"
     )}
  end

  @doc """
  `:page_size` must be a non-negative int32 (0 means the server default; larger
  values are capped by the server) and `:page_token` a binary. `nil` means the
  default for both, as protobuf skipped nil fields before validation existed.
  """
  @spec validate_page_opts(keyword()) :: {:ok, keyword()} | {:error, Error.t()}
  def validate_page_opts(opts) do
    case {Keyword.get(opts, :page_size) || 0, Keyword.get(opts, :page_token) || ""} do
      {size, _} when not (is_integer(size) and size >= 0 and size <= @max_int32) ->
        {:error,
         Error.new(
           :validation_error,
           "page_size must be a non-negative integer of at most #{@max_int32}"
         )}

      {_, token} when not is_binary(token) ->
        {:error, Error.new(:validation_error, "page_token must be a string")}

      _ ->
        {:ok, opts}
    end
  end

  @spec validate_binary(term(), String.t()) :: {:ok, binary()} | {:error, Error.t()}
  def validate_binary(value, _field) when is_binary(value), do: {:ok, value}

  def validate_binary(_value, field) do
    {:error, Error.new(:validation_error, "#{field} must be a binary")}
  end

  # Private

  defp unknown_keys(opts, allowed_keys) do
    for {key, _value} <- opts, key not in allowed_keys, uniq: true, do: key
  end

  defp validate_opt_values(opts) do
    with {:ok, _} <- validate_timeout_opt(opts),
         {:ok, _} <- validate_pool_opt(opts) do
      validate_page_opts(opts)
    end
  end

  # `timeout: nil` means the default, as before validation existed.
  defp validate_timeout_opt(opts) do
    case Keyword.get(opts, :timeout) do
      nil -> {:ok, nil}
      timeout -> validate_timeout(timeout)
    end
  end

  # Pool names are atoms (`nil` means the configured pool). Anything else would
  # raise in grpc_connection_pool, or create atoms from caller input.
  defp validate_pool_opt(opts) do
    case Keyword.get(opts, :pool) do
      pool when is_atom(pool) -> {:ok, pool}
      _ -> {:error, Error.new(:validation_error, "pool must be a pool name (an atom)")}
    end
  end

  # A message needs non-empty :data (binary) or non-empty :attributes (a plain
  # map: a struct is not enumerable).
  defp message_fields(%{} = message) do
    data = Map.get(message, :data, "")
    attributes = Map.get(message, :attributes, %{})

    if is_binary(data) and is_map(attributes) and not is_struct(attributes) and
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

  # Attributes are `map<string, string>`: anything else would raise when the
  # request is encoded, after pool checkout.
  defp attributes_bytes(attributes) do
    Enum.reduce_while(attributes, {:ok, 0}, fn
      {key, value}, {:ok, acc} when is_binary(key) and is_binary(value) ->
        {:cont, {:ok, acc + byte_size(key) + byte_size(value)}}

      _attribute, _acc ->
        {:halt,
         {:error,
          Error.new(:validation_error, "message attributes must map string keys to string values")}}
    end)
  end

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
