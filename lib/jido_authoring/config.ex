defmodule Jido.Authoring.Config do
  @moduledoc false

  alias Jido.Action.Validation
  alias Jido.Flow.Error

  @keys [:name, :description, :schema, :output_schema]

  @max_action_name_bytes 256
  @action_config_schema Zoi.object(
                          %{
                            name:
                              Zoi.string(
                                description: "The non-blank metadata name of the Action."
                              )
                              |> Zoi.refine({__MODULE__, :validate_name, []}),
                            description:
                              Zoi.string(description: "A description of what the Action does.")
                              |> Zoi.optional(),
                            schema:
                              Zoi.any(
                                description:
                                  "A Zoi schema for validating the Action's input parameters."
                              )
                              |> Zoi.refine({__MODULE__, :validate_map_schema, []})
                              |> Zoi.default([]),
                            output_schema:
                              Zoi.any(
                                description:
                                  "A Zoi schema for validating the Action's output. Only specified fields are validated."
                              )
                              |> Zoi.refine({__MODULE__, :validate_map_schema, []})
                              |> Zoi.default([])
                          },
                          unrecognized_keys: :error
                        )

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

  @doc false
  @spec ensure_static_schema!(term(), atom(), Macro.Env.t()) :: term() | no_return()
  def ensure_static_schema!(schema, option, env) do
    case validate_static_data(schema) do
      :ok ->
        :ok

      {:error, reason} ->
        raise CompileError,
          description:
            "#{inspect(option)} must be static module data; #{reason}. " <>
              "Use named MFA effects such as {Module, :function, args}",
          file: env.file,
          line: env.line
    end

    ensure_escapable_schema!(schema, option, env)
  end

  defp ensure_escapable_schema!(schema, option, env) do
    case escapable_static_schema?(schema) do
      true ->
        schema

      false ->
        raise CompileError,
          description:
            "#{inspect(option)} must be static module data that can be stored in the Action module. " <>
              "Use named MFA effects such as {Module, :function, args}",
          file: env.file,
          line: env.line
    end
  end

  defp escapable_static_schema?(schema) do
    Macro.escape(schema)
    true
  rescue
    ArgumentError -> false
  end

  @doc false
  @spec prepare_action!(term(), Macro.Env.t()) ::
          {map(), Jido.Action.schema(), Jido.Action.schema()} | no_return()
  def prepare_action!(raw_opts, env) do
    opts_map =
      if is_list(raw_opts) and Keyword.keyword?(raw_opts),
        do: Map.new(raw_opts),
        else: raw_opts

    if is_map(opts_map) do
      ensure_static_schema!(Map.get(opts_map, :schema, []), :schema, env)
      ensure_static_schema!(Map.get(opts_map, :output_schema, []), :output_schema, env)
    end

    case Zoi.parse(@action_config_schema, opts_map) do
      {:ok, validated_opts} ->
        validated_opts =
          if is_struct(validated_opts), do: Map.from_struct(validated_opts), else: validated_opts

        {validated_opts, Map.fetch!(validated_opts, :schema),
         Map.fetch!(validated_opts, :output_schema)}

      {:error, errors} ->
        message = "Action configuration validation failed:\n" <> Zoi.prettify_errors(errors)

        raise CompileError, description: message, file: env.file, line: env.line
    end
  end

  @doc false
  @spec prepare!(Jido.Instruction.kind(), term(), Macro.Env.t()) ::
          {map(), Jido.Action.schema(), Jido.Action.schema()} | no_return()
  def prepare!(:action, raw_opts, env), do: prepare_action!(raw_opts, env)

  def prepare!(:flow, raw_opts, env) do
    case validate_flow(normalize_options(raw_opts)) do
      {:ok, opts} ->
        schema = ensure_escapable_schema!(opts.schema, :schema, env)
        output_schema = ensure_escapable_schema!(opts.output_schema, :output_schema, env)
        {opts, schema, output_schema}

      {:error, error} ->
        raise CompileError,
          description: "Flow configuration validation failed: #{Exception.message(error)}",
          file: env.file,
          line: env.line
    end
  end

  @doc false
  @spec validate_flow(term()) :: {:ok, map()} | {:error, Exception.t()}
  def validate_flow(%{} = attrs) when not is_struct(attrs) do
    with :ok <- known_keys(attrs),
         {:ok, name} <- flow_name(Map.get(attrs, :name)),
         {:ok, description} <- description(Map.get(attrs, :description)),
         {:ok, schema} <- schema(Map.get(attrs, :schema, []), "schema"),
         {:ok, output_schema} <- schema(Map.get(attrs, :output_schema, []), "output_schema") do
      {:ok, %{name: name, description: description, schema: schema, output_schema: output_schema}}
    end
  end

  def validate_flow(_attrs),
    do: {:error, Error.validation_error("flow configuration must be a map")}

  @doc false
  @spec flow_name(term()) :: {:ok, String.t()} | {:error, Exception.t()}
  def flow_name(value) when is_binary(value) do
    case validate_name(value) do
      :ok -> {:ok, value}
      {:error, message} -> {:error, Error.validation_error(message)}
    end
  end

  def flow_name(_value), do: {:error, Error.validation_error("flow name must be a string")}

  @doc false
  @spec description(term()) :: {:ok, String.t() | nil} | {:error, Exception.t()}
  def description(nil), do: {:ok, nil}

  def description(value) when is_binary(value) do
    if String.valid?(value),
      do: {:ok, value},
      else: {:error, Error.validation_error("flow description must be valid UTF-8")}
  end

  def description(_value),
    do: {:error, Error.validation_error("flow description must be a string")}

  @doc false
  @spec schema(term(), String.t()) :: {:ok, Jido.Action.schema()} | {:error, Exception.t()}
  def schema(nil, _field), do: {:ok, []}

  def schema(value, field) do
    with :ok <- static_schema(value),
         :ok <- validate_map_schema(value) do
      {:ok, value}
    else
      {:error, message} ->
        {:error, Error.validation_error("#{field} #{message}", %{field: field})}
    end
  end

  defp static_schema(value) do
    case validate_static_data(value) do
      :ok -> :ok
      {:error, message} -> {:error, "must be static module data; #{message}"}
    end
  end

  defp known_keys(attrs) do
    case Enum.reject(Map.keys(attrs), &(&1 in @keys)) do
      [] ->
        :ok

      [key | _] ->
        {:error,
         Error.validation_error("unknown Flow configuration key: #{inspect(key)}", %{key: key})}
    end
  end

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
