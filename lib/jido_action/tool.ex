defmodule Jido.Action.Tool do
  @moduledoc """
  Provides functionality to convert Jido Actions into generic tool representations.

  This module allows Jido Actions to be converted into standardized tool maps
  that can be used by various AI integration layers.

  Tool execution preserves the legacy `{:ok, json}` / `{:error, json}` contract.
  Successful results are sanitized before JSON encoding, and failures still
  serialize as `%{"error" => binary}` payloads with sanitizer-backed fallback
  when raw inspection is unsafe.

  ## Tool Formats

  - `to_tool/1` - Returns a generic tool map with name, description, function, and schema
  - `to_tool/2` - Same as `to_tool/1` with JSON schema options (e.g., strict mode)

  ## Utility Functions

  - `convert_params_using_schema/2` - Normalizes LLM arguments (string keys → atom keys, type coercion)
  - `build_parameters_schema/1` - Converts action schema to JSON Schema format
  - `build_parameters_schema/2` - Same as `build_parameters_schema/1` with schema options
  - `execute_action/3` - Executes an action with schema-based param conversion
  """

  alias Jido.Action.{Error, Sanitizer, Schema}

  @type tool :: %{
          name: String.t(),
          description: String.t(),
          function: (map(), map() -> {:ok, String.t()} | {:error, String.t()}),
          parameters_schema: map()
        }

  @doc """
  Converts a Jido Exec into a tool representation.

  ## Arguments

    * `action` - The module implementing the Jido.Action behavior.

  ## Returns

    A map representing the action as a tool, compatible with systems like LangChain.

  ## Examples

      iex> tool = Jido.Action.Tool.to_tool(MyExec)
      %{
        name: "my_action",
        description: "Performs a specific task",
        function: #Function<...>,
        parameters_schema: %{...}
      }
  """
  @spec to_tool(module()) :: tool()
  def to_tool(action) when is_atom(action), do: to_tool(action, [])

  @spec to_tool(module(), keyword()) :: tool()
  def to_tool(action, opts) when is_atom(action) and is_list(opts) do
    %{
      name: action.name(),
      description: action.description(),
      function: &execute_action(action, &1, &2),
      parameters_schema: build_parameters_schema(action.schema(), opts)
    }
  end

  @doc """
  Executes an action and formats the result for tool output.

  This function is typically used as the function value in the tool representation.
  Error payloads intentionally remain the legacy `%{"error" => binary}` JSON
  shape for compatibility.
  """
  @spec execute_action(module(), map(), map()) :: {:ok, String.t()} | {:error, String.t()}
  def execute_action(action, params, context) do
    # Convert string keys to atom keys and handle type conversion based on schema
    converted_params = convert_params_using_schema(params, action.schema())
    safe_context = context || %{}

    case Jido.Exec.run(action, converted_params, safe_context) do
      {:ok, result} ->
        {:ok, result |> Sanitizer.sanitize() |> Jason.encode!()}

      {:error, %_{} = error} when is_exception(error) ->
        {:error, encode_error_payload(error_message(error))}

      {:error, reason} ->
        {:error, encode_error_payload(reason_message(reason))}
    end
  end

  @doc """
  Helper function to convert params using schema information.

  Converts string keys to atom keys and handles type conversion based on schema.
  Supports both atom and string input keys, and preserves unknown keys (open validation).
  A present `nil` value is dropped only when the key is optional and its schema
  does not allow `nil`, so an action default can still apply. Required keys and
  keys whose schemas allow `nil` keep the value for validation.
  """
  def convert_params_using_schema(params, schema) when is_map(params) do
    case Schema.schema_type(schema) do
      :json_schema ->
        convert_params_using_json_schema(params, schema)

      :zoi ->
        convert_params_using_zoi_schema(params, schema)

      _ ->
        schema_keys = Schema.known_keys(schema)
        convert_params_using_known_keys(params, schema, schema_keys)
    end
  end

  defp convert_params_using_json_schema(params, schema) do
    key_pairs =
      schema
      |> Schema.json_schema_known_key_forms()
      |> Enum.flat_map(fn
        %{atom: atom, string: string} when is_atom(atom) and not is_nil(atom) ->
          [{atom, string}]

        _ ->
          []
      end)

    convert_params_using_key_pairs(params, schema, key_pairs)
  end

  defp convert_params_using_known_keys(params, schema, schema_keys) do
    key_pairs = Enum.map(schema_keys, fn key -> {key, to_string(key)} end)
    convert_params_using_key_pairs(params, schema, key_pairs)
  end

  defp convert_params_using_key_pairs(params, schema, key_pairs) do
    convert_params_using_key_pairs(params, schema, key_pairs, &convert_value_with_schema/3)
  end

  defp convert_params_using_key_pairs(params, schema, key_pairs, convert_value) do
    {known_converted, unknown_params} =
      Enum.reduce(key_pairs, {%{}, params}, fn {key, string_key}, {known_acc, rest} ->
        {atom_value, rest} = Map.pop(rest, key, :__missing__)

        {value, rest} =
          case atom_value do
            :__missing__ ->
              Map.pop(rest, string_key, :__missing__)

            _ ->
              {_dropped_string_value, rest2} = Map.pop(rest, string_key, :__missing__)
              {atom_value, rest2}
          end

        case value do
          :__missing__ ->
            {known_acc, rest}

          nil ->
            if preserve_nil?(schema, key) do
              converted_value = convert_value.(schema, key, value)
              {Map.put(known_acc, key, converted_value), rest}
            else
              {known_acc, rest}
            end

          _ ->
            converted_value = convert_value.(schema, key, value)
            {Map.put(known_acc, key, converted_value), rest}
        end
      end)

    Map.merge(unknown_params, known_converted)
  end

  defp preserve_nil?(schema, key),
    do: required_key?(schema, key) or nil_allowed?(schema, key)

  # Reports whether `key` is required in `schema`. Supports NimbleOptions keyword
  # schemas and JSON Schema object maps with atom or string keys.
  defp required_key?(schema, key) when is_list(schema) do
    schema
    |> Keyword.get(key, [])
    |> Keyword.get(:required, false)
  end

  defp required_key?(schema, key) when is_map(schema) do
    required = Map.get(schema, "required") || Map.get(schema, :required) || []
    string_key = to_string(key)

    Enum.any?(required, fn
      ^string_key -> true
      other when is_atom(other) -> other == key
      _ -> false
    end)
  end

  defp nil_allowed?(schema, key) when is_list(schema) do
    schema
    |> Keyword.get(key, [])
    |> Keyword.get(:type, :any)
    |> nimble_type_allows_nil?()
  end

  defp nil_allowed?(schema, key) when is_map(schema) do
    with properties when is_map(properties) <- json_schema_properties(schema),
         {:ok, property_schema} <- fetch_json_schema_property(properties, key) do
      json_schema_allows_nil?(property_schema)
    else
      _ -> false
    end
  end

  defp nimble_type_allows_nil?(type) when type in [:any, :atom, nil], do: true
  defp nimble_type_allows_nil?({:in, choices}), do: Enum.member?(choices, nil)

  defp nimble_type_allows_nil?({:or, subtypes}),
    do: Enum.any?(subtypes, &nimble_type_allows_nil?/1)

  defp nimble_type_allows_nil?(_type), do: false

  defp convert_params_using_zoi_schema(params, schema) do
    params
    |> convert_params_using_json_object_schema(Schema.to_json_schema(schema))
  end

  defp convert_params_using_json_object_schema(params, schema) when is_map(params) do
    case json_schema_properties(schema) do
      properties when is_map(properties) ->
        convert_params_using_json_object_properties(params, schema, properties)

      _ ->
        params
    end
  end

  defp convert_params_using_json_object_properties(params, schema, properties) do
    key_pairs = Map.keys(properties) |> Enum.map(&{&1, to_string(&1)})

    convert_params_using_key_pairs(params, schema, key_pairs, fn schema, key, value ->
      schema
      |> json_schema_properties()
      |> Map.fetch!(key)
      |> convert_json_schema_value(value)
    end)
  end

  defp convert_json_schema_value(schema, value) when is_map(value) do
    cond do
      json_schema_type(schema) in [:object, "object"] ->
        convert_params_using_json_object_schema(value, schema)

      schemas = json_schema_composite_schemas(schema) ->
        Enum.reduce(schemas, value, &convert_json_schema_value/2)

      true ->
        value
    end
  end

  defp convert_json_schema_value(schema, value) when is_list(value) do
    case {json_schema_type(schema), json_schema_items(schema)} do
      {type, item_schema} when type in [:array, "array"] and is_map(item_schema) ->
        Enum.map(value, &convert_json_schema_value(item_schema, &1))

      _ ->
        value
    end
  end

  defp convert_json_schema_value(_schema, value), do: value

  defp json_schema_type(schema), do: Map.get(schema, :type) || Map.get(schema, "type")

  defp json_schema_properties(schema),
    do: Map.get(schema, :properties) || Map.get(schema, "properties")

  defp json_schema_items(schema), do: Map.get(schema, :items) || Map.get(schema, "items")

  defp fetch_json_schema_property(properties, key) do
    case Map.fetch(properties, key) do
      {:ok, property_schema} -> {:ok, property_schema}
      :error -> Map.fetch(properties, to_string(key))
    end
  end

  defp json_schema_allows_nil?(true), do: true
  defp json_schema_allows_nil?(false), do: false

  defp json_schema_allows_nil?(schema) when is_map(schema) do
    json_schema_type_allows_nil?(schema) and
      json_schema_enum_allows_nil?(schema) and
      json_schema_const_allows_nil?(schema) and
      json_schema_composite_allows_nil?(schema, :allOf, &Enum.all?/1) and
      json_schema_composite_allows_nil?(schema, :anyOf, &Enum.any?/1) and
      json_schema_one_of_allows_nil?(schema) and
      json_schema_not_allows_nil?(schema)
  end

  defp json_schema_allows_nil?(_schema), do: false

  defp json_schema_type_allows_nil?(schema) do
    if json_schema_keyword(schema, :nullable, false) do
      true
    else
      case json_schema_keyword(schema, :type, :__missing__) do
        :__missing__ -> true
        types when is_list(types) -> Enum.any?(types, &(&1 in [:null, "null"]))
        type -> type in [:null, "null"]
      end
    end
  end

  defp json_schema_enum_allows_nil?(schema) do
    case json_schema_keyword(schema, :enum, :__missing__) do
      :__missing__ -> true
      values when is_list(values) -> Enum.member?(values, nil)
      _ -> false
    end
  end

  defp json_schema_const_allows_nil?(schema) do
    case json_schema_keyword(schema, :const, :__missing__) do
      :__missing__ -> true
      nil -> true
      _ -> false
    end
  end

  defp json_schema_composite_allows_nil?(schema, keyword, predicate) do
    case json_schema_keyword(schema, keyword, :__missing__) do
      :__missing__ ->
        true

      schemas when is_list(schemas) ->
        schemas |> Enum.map(&json_schema_allows_nil?/1) |> predicate.()

      _ ->
        false
    end
  end

  defp json_schema_one_of_allows_nil?(schema) do
    case json_schema_keyword(schema, :oneOf, :__missing__) do
      :__missing__ -> true
      schemas when is_list(schemas) -> Enum.count(schemas, &json_schema_allows_nil?/1) == 1
      _ -> false
    end
  end

  defp json_schema_not_allows_nil?(schema) do
    case json_schema_keyword(schema, :not, :__missing__) do
      :__missing__ -> true
      nested_schema -> not json_schema_allows_nil?(nested_schema)
    end
  end

  defp json_schema_keyword(schema, key, default) do
    case Map.fetch(schema, key) do
      {:ok, value} -> value
      :error -> Map.get(schema, Atom.to_string(key), default)
    end
  end

  defp json_schema_composite_schemas(schema) do
    Enum.find_value([:allOf, "allOf", :anyOf, "anyOf", :oneOf, "oneOf"], fn key ->
      case Map.get(schema, key) do
        schemas when is_list(schemas) -> schemas
        _ -> nil
      end
    end)
  end

  defp convert_value_with_schema(schema, key, value) when is_list(schema) do
    schema_entry = Keyword.get(schema, key, [])
    type = Keyword.get(schema_entry, :type)
    coerce_value(type, value)
  end

  defp convert_value_with_schema(_schema, _key, value) do
    # For Zoi schemas, let the validation handle conversion
    value
  end

  defp coerce_value(:float, value) when is_binary(value) do
    parse_float(value)
  end

  defp coerce_value(:float, value) when is_integer(value) do
    value * 1.0
  end

  defp coerce_value(:integer, value) when is_binary(value) do
    parse_integer(value)
  end

  defp coerce_value(_type, value), do: value

  defp parse_float(value) do
    case Float.parse(value) do
      {num, _} -> num
      :error -> value
    end
  end

  defp parse_integer(value) do
    case Integer.parse(value) do
      {num, _} -> num
      :error -> value
    end
  end

  @doc """
  Builds a parameters schema for the tool based on the action's schema.

  ## Arguments

    * `schema` - The NimbleOptions or Zoi schema from the action.

  ## Returns

    A map representing the parameters schema in a format compatible with LangChain.
  """
  @spec build_parameters_schema(Schema.t()) :: map()
  def build_parameters_schema(schema), do: build_parameters_schema(schema, [])

  @spec build_parameters_schema(Schema.t(), keyword()) :: map()
  def build_parameters_schema(schema, opts) when is_list(opts),
    do: Schema.to_json_schema(schema, opts)

  defp encode_error_payload(message), do: Jason.encode!(%{error: message})

  defp error_message(error) do
    inspect(error)
  rescue
    _ ->
      error
      |> Error.to_map()
      |> inspect()
  end

  defp reason_message(reason) do
    inspect(reason)
  rescue
    _ ->
      reason
      |> Sanitizer.sanitize()
      |> inspect()
  end
end
