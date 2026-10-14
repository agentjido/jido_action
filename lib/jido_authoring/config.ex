defmodule Jido.Authoring.Config do
  @moduledoc false

  alias Jido.Action.Validation
  alias Jido.Flow.Error

  @keys [:name, :description, :schema, :output_schema]
  @max_action_name_bytes 256

  @doc false
  @spec validate_name(term(), keyword()) :: :ok | {:error, String.t()}
  def validate_name(name, _opts \\ [])

  def validate_name(name, _opts) when is_binary(name) do
    cond do
      not String.valid?(name) ->
        {:error, "Action name must be valid UTF-8."}

      String.trim(name) == "" ->
        {:error, "Action name cannot be blank."}

      byte_size(name) > @max_action_name_bytes ->
        {:error, "Action name cannot exceed #{@max_action_name_bytes} bytes."}

      true ->
        :ok
    end
  end

  def validate_name(_name, _opts) do
    {:error, "Action name must be a string."}
  end

  @doc false
  @spec validate_config_schema(term(), keyword()) :: :ok | {:error, String.t()}
  def validate_config_schema(value, _opts \\ [])

  def validate_config_schema([], _opts), do: :ok

  def validate_config_schema(value, _opts) do
    if Validation.zoi_schema?(value) do
      :ok
    else
      {:error, "must be a Zoi schema"}
    end
  end

  @doc false
  @spec validate_map_schema(term(), keyword()) :: :ok | {:error, String.t()}
  def validate_map_schema(value, opts \\ []) do
    with :ok <- validate_config_schema(value, opts) do
      if value == [] or Validation.map_schema?(value) do
        :ok
      else
        {:error, "must accept map-shaped data"}
      end
    end
  end

  @doc false
  @spec validate_static_data(term()) :: :ok | {:error, String.t()}
  def validate_static_data(term), do: static_schema_data(term, [])

  defp ensure_escapable_schema!(schema, option, env) do
    Macro.escape(schema)
    schema
  rescue
    ArgumentError ->
      raise CompileError,
        description:
          "#{inspect(option)} must be static module data that can be stored in the Action module. " <>
            "Use named MFA effects such as {Module, :function, args}",
        file: env.file,
        line: env.line
  end

  @doc false
  @spec prepare!(Jido.Instruction.kind(), term(), Macro.Env.t()) ::
          {map(), Jido.Action.schema(), Jido.Action.schema()} | no_return()
  def prepare!(kind, raw_opts, env) do
    case validate_config(kind, normalize_options(raw_opts)) do
      {:ok, opts} ->
        schema = ensure_escapable_schema!(opts.schema, :schema, env)
        output_schema = ensure_escapable_schema!(opts.output_schema, :output_schema, env)
        {opts, schema, output_schema}

      {:error, errors} ->
        raise CompileError,
          description: compile_error(kind, errors),
          file: env.file,
          line: env.line
    end
  end

  @doc false
  @spec validate_flow(term()) :: {:ok, map()} | {:error, Exception.t()}
  def validate_flow(attrs) do
    case validate_config(:flow, attrs) do
      {:ok, opts} -> {:ok, opts}
      {:error, [error | _]} -> {:error, flow_error(error)}
    end
  end

  defp validate_config(kind, %{} = attrs) when not is_struct(attrs) do
    {values, errors} =
      Enum.reduce(@keys, {%{}, []}, fn field, {values, errors} ->
        case {kind, field, Map.fetch(attrs, field)} do
          {:action, :description, :error} ->
            {values, errors}

          {:action, :name, :error} ->
            {values, errors ++ [{field, :required}]}

          _ ->
            case validate_field(kind, field, Map.get(attrs, field)) do
              {:ok, value} -> {Map.put(values, field, value), errors}
              {:error, reason} -> {values, errors ++ [{field, reason}]}
            end
        end
      end)

    unknown = for key <- Map.keys(attrs), key not in @keys, do: {nil, {:unknown, key}}
    errors = if kind == :action, do: errors ++ unknown, else: unknown ++ errors

    if errors == [], do: {:ok, values}, else: {:error, errors}
  end

  defp validate_config(_kind, _attrs), do: {:error, [{nil, :map}]}

  defp validate_field(_kind, :name, value) when is_binary(value) do
    case validate_name(value) do
      :ok -> {:ok, value}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_field(:flow, :description, nil), do: {:ok, nil}

  defp validate_field(kind, :description, value) when is_binary(value) do
    if kind == :flow and not String.valid?(value),
      do: {:error, "flow description must be valid UTF-8"},
      else: {:ok, value}
  end

  defp validate_field(_kind, field, _value) when field in [:name, :description],
    do: {:error, :string}

  defp validate_field(_kind, _field, nil), do: {:ok, []}

  defp validate_field(_kind, _field, value) do
    with :ok <- static_schema(value),
         :ok <- validate_map_schema(value) do
      {:ok, value}
    end
  end

  @doc false
  @spec flow_name(term()) :: {:ok, String.t()} | {:error, Exception.t()}
  def flow_name(value), do: flow_field(:name, value)

  @doc false
  @spec description(term()) :: {:ok, String.t() | nil} | {:error, Exception.t()}
  def description(value), do: flow_field(:description, value)

  @doc false
  @spec schema(term(), String.t()) :: {:ok, Jido.Action.schema()} | {:error, Exception.t()}
  def schema(value, field), do: flow_field(field, value)

  defp flow_field(field, value) do
    case validate_field(:flow, field, value) do
      {:ok, value} -> {:ok, value}
      {:error, reason} -> {:error, flow_error({field, reason})}
    end
  end

  defp static_schema(value) do
    case validate_static_data(value) do
      :ok -> :ok
      {:error, message} -> {:error, {:static, message}}
    end
  end

  defp compile_error(:flow, [error | _]),
    do: "Flow configuration validation failed: #{Exception.message(flow_error(error))}"

  defp compile_error(:action, errors) do
    case Enum.find(errors, fn {_field, reason} -> match?({:static, _}, reason) end) do
      {field, {:static, reason}} ->
        "#{inspect(field)} must be static module data; #{reason}. " <>
          "Use named MFA effects such as {Module, :function, args}"

      nil ->
        "Action configuration validation failed:\n" <>
          Enum.map_join(errors, "\n", &action_error/1)
    end
  end

  defp action_error({nil, {:unknown, key}}), do: Zoi.Error.unrecognized_key(key).message
  defp action_error({nil, :map}), do: "invalid type: expected map"
  defp action_error({field, :required}), do: "is required, at #{field}"
  defp action_error({field, :string}), do: "invalid type: expected string, at #{field}"
  defp action_error({field, reason}), do: "#{reason}, at #{field}"

  defp flow_error({nil, {:unknown, key}}),
    do: Error.validation_error("unknown Flow configuration key: #{inspect(key)}", %{key: key})

  defp flow_error({nil, :map}), do: Error.validation_error("flow configuration must be a map")
  defp flow_error({field, :string}), do: Error.validation_error("flow #{field} must be a string")

  defp flow_error({field, {:static, reason}}),
    do: flow_error({field, "must be static module data; #{reason}"})

  defp flow_error({field, reason}) when field in [:name, :description],
    do: Error.validation_error(reason)

  defp flow_error({field, reason}),
    do: Error.validation_error("#{field} #{reason}", %{field: to_string(field)})

  defp normalize_options(raw_opts) when is_list(raw_opts) do
    if Keyword.keyword?(raw_opts), do: Map.new(raw_opts), else: raw_opts
  end

  defp normalize_options(raw_opts), do: raw_opts

  defp static_schema_data(%Zoi.Types.Lazy{}, path),
    do: static_data_error("lazy schemas are not supported", path)

  defp static_schema_data(term, path) when is_function(term),
    do: static_data_error("anonymous functions are not supported", path)

  defp static_schema_data(term, path)
       when is_pid(term) or is_port(term) or is_reference(term),
       do: static_data_error("runtime process values are not supported", path)

  defp static_schema_data(term, path) when is_map(term) do
    term
    |> Map.to_list()
    |> Enum.sort_by(fn {key, _value} -> :erlang.term_to_binary(key) end)
    |> Enum.reduce_while(:ok, fn {key, value}, :ok ->
      with :ok <- static_schema_data(key, path ++ [:key]),
           :ok <- static_schema_data(value, path ++ [key]) do
        {:cont, :ok}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp static_schema_data(term, path) when is_list(term) do
    static_schema_list_data(term, path, 0)
  end

  defp static_schema_data(term, path) when is_tuple(term) do
    term
    |> Tuple.to_list()
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {value, index}, :ok ->
      case static_schema_data(value, path ++ [index]) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp static_schema_data(_term, _path), do: :ok

  defp static_schema_list_data([], _path, _index), do: :ok

  defp static_schema_list_data([value | rest], path, index) when is_list(rest) do
    case static_schema_data(value, path ++ [index]) do
      :ok -> static_schema_list_data(rest, path, index + 1)
      {:error, reason} -> {:error, reason}
    end
  end

  defp static_schema_list_data([value | _tail], path, index) do
    with :ok <- static_schema_data(value, path ++ [index]) do
      static_data_error("improper list tails are not supported", path ++ [index + 1])
    end
  end

  defp static_data_error(reason, []), do: {:error, reason}
  defp static_data_error(reason, path), do: {:error, "#{reason} at #{inspect(path)}"}
end
