defmodule Jido.Action do
  @moduledoc """
  Defines one named, validated unit of work.

  Use `Jido.Action` in a module, declare static input and output schemas, and
  implement `c:run/2`:

      defmodule MyAction do
        use Jido.Action,
          name: "my_action",
          description: "Performs my action",
          schema: Zoi.object(%{input: Zoi.string()}),
          output_schema: Zoi.object(%{result: Zoi.string()})

      @impl true
      def run(params, _context) do
        # Your action logic here
        {:ok, %{result: String.upcase(params.input)}}
      end
    end

  ## Validation and execution

  The generated `validate_params/1` and `validate_output/1` functions apply the
  declared schemas. Object schemas are open: declared fields are validated and
  unknown fields stay in the returned map.

  A direct callback call does not add validation. Validate both boundaries
  explicitly when you call `run/2` yourself:

      {:ok, params} = MyAction.validate_params(%{input: "hello"})
      {:ok, result} = MyAction.run(params, %{})
      {:ok, result} = MyAction.validate_output(result)

  Use `Jido.Exec.run/4` when you want the public validation and error boundary.
  It validates input, calls the Action, validates normal output, and normalizes
  failures.

  ## Effects and policy

  `run/2` can be pure or can perform I/O. Keep one Action focused on one unit
  of work. The caller selects retry, timeout, scheduling, cancellation, and
  persistence policy. `Jido.Exec` enforces a requested execution timeout and
  owns process cleanup. It does not retry an Action automatically.
  """

  alias Jido.Action.{Error, Output, Validation}

  @typedoc "A static Action input or output schema."
  @type schema :: Zoi.schema() | []

  @typedoc "A supported Action callback result."
  @type result ::
          {:ok, map() | Output.t()}
          | {:ok, map() | Output.t(), term()}
          | {:error, term()}
          | {:error, term(), term()}

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
                              |> Zoi.refine({__MODULE__, :validate_action_schema, []})
                              |> Zoi.default([]),
                            output_schema:
                              Zoi.any(
                                description:
                                  "A Zoi schema for validating the Action's output. Only specified fields are validated."
                              )
                              |> Zoi.refine({__MODULE__, :validate_action_schema, []})
                              |> Zoi.default([])
                          },
                          unrecognized_keys: :error
                        )

  @doc false
  @spec validate_name(term(), keyword()) :: :ok | {:error, String.t()}
  def validate_name(name, _opts \\ [])

  def validate_name(name, _opts) when is_binary(name) do
    cond do
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
  @spec validate_action_schema(term(), keyword()) :: :ok | {:error, String.t()}
  def validate_action_schema(value, opts \\ []) do
    with :ok <- validate_config_schema(value, opts) do
      if value == [] or Validation.action_schema?(value) do
        :ok
      else
        {:error, "must accept map-shaped action data"}
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
  @spec validate_params_for(map(), module()) ::
          {:ok, map()} | {:error, Error.InvalidInputError.t()}
  def validate_params_for(params, module) do
    with {:ok, validated} <- validate_data(module.schema(), params, "Action", module) do
      validate_action_map(validated, "Action", module)
    end
  end

  @doc false
  @spec validate_output_for(map() | Output.t(), module()) ::
          {:ok, map() | Output.t()} | {:error, Error.InvalidInputError.t()}
  def validate_output_for(%Output{} = output, _module), do: Output.validate(output)

  def validate_output_for(output, module) do
    with {:ok, validated} <-
           validate_data(module.output_schema(), output, "Action output", module) do
      validate_action_map(validated, "Action output", module)
    end
  end

  @validate_params_doc """
  Validates the input parameters for the Action.

  Returns `{:ok, validated_params}` or
  `{:error, %Jido.Action.Error.InvalidInputError{}}`. Open object schemas
  preserve unknown keys in the validated map.
  """

  @validate_output_doc """
  Validates the output result for the Action.

  Returns `{:ok, validated_output}` or
  `{:error, %Jido.Action.Error.InvalidInputError{}}`. Open object schemas
  preserve unknown keys in the validated map. An explicit
  `Jido.Action.Output` envelope is validated as an envelope.
  """

  @doc """
  Defines a new Action module.

  This macro sets up the necessary structure and callbacks for an Action,
  including configuration validation and default implementations.

  ## Options

  - `name` (required) - The non-blank metadata name of the Action.
  - `description` (optional) - A description of what the Action does.
  - `schema` (optional, default: `[]`) - A Zoi schema for Action input.
  - `output_schema` (optional, default: `[]`) - A Zoi schema for Action output.

  Schemas must be static module data. Use named MFA tuples for Zoi refinements,
  transforms, and other effects. Anonymous functions and lazy schemas are not
  supported because they can change the schema after compile-time validation.

  ## Examples

      defmodule MyAction do
        use Jido.Action,
          name: "my_action",
          description: "Performs a specific task",
          schema:
            Zoi.object(%{
              input:
                Zoi.string()
                |> Zoi.refine({__MODULE__, :not_blank, []})
            })

        def not_blank(value, _opts) do
          if String.trim(value) == "", do: {:error, "cannot be blank"}, else: :ok
        end

        @impl true
        def run(params, _context) do
          {:ok, %{result: String.upcase(params.input)}}
        end
      end

  """
  defmacro __using__(opts_ast) do
    escaped_schema = Macro.escape(@action_config_schema)
    validate_params_doc = @validate_params_doc
    validate_output_doc = @validate_output_doc

    quote location: :keep do
      @behaviour Jido.Action
      @behaviour Jido.Executable

      alias Jido.Action

      # Convert opts to map for Zoi validation (including nested keyword lists)
      raw_opts = unquote(opts_ast)

      opts_map =
        if is_list(raw_opts) and Keyword.keyword?(raw_opts) do
          Map.new(raw_opts)
        else
          raw_opts
        end

      # Reject dynamic schema kinds before configuration validation can resolve them.
      if is_map(opts_map) do
        Action.ensure_static_schema!(Map.get(opts_map, :schema, []), :schema, __ENV__)

        Action.ensure_static_schema!(
          Map.get(opts_map, :output_schema, []),
          :output_schema,
          __ENV__
        )
      end

      case Zoi.parse(unquote(escaped_schema), opts_map) do
        {:ok, validated_opts} ->
          # Convert Zoi struct to map for backward compatibility
          validated_opts =
            if is_struct(validated_opts),
              do: Map.from_struct(validated_opts),
              else: validated_opts

          stored_schema =
            Action.ensure_static_schema!(
              Map.get(validated_opts, :schema, []),
              :schema,
              __ENV__
            )

          stored_output_schema =
            Action.ensure_static_schema!(
              Map.get(validated_opts, :output_schema, []),
              :output_schema,
              __ENV__
            )

          Module.put_attribute(__MODULE__, :__jido_schema__, stored_schema)
          Module.put_attribute(__MODULE__, :__jido_output_schema__, stored_output_schema)

          @validated_opts Map.drop(validated_opts, [:schema, :output_schema])

          @doc "Returns the name of the Action."
          @spec name() :: String.t()
          def name, do: @validated_opts[:name]

          @doc "Returns the description of the Action."
          @spec description() :: String.t() | nil
          def description, do: @validated_opts[:description]

          @doc "Returns the input schema of the Action."
          @spec schema() :: Jido.Action.schema()
          def schema, do: @__jido_schema__

          @doc "Returns the output schema of the Action."
          @spec output_schema() :: Jido.Action.schema()
          def output_schema, do: @__jido_output_schema__

          @doc false
          @spec __jido_executable__() :: Jido.Executable.t()
          def __jido_executable__, do: Jido.Executable.action(__MODULE__)

          @doc unquote(validate_params_doc)
          @spec validate_params(map()) ::
                  {:ok, map()} | {:error, Jido.Action.Error.InvalidInputError.t()}
          def validate_params(params), do: Action.validate_params_for(params, __MODULE__)

          @doc unquote(validate_output_doc)
          @spec validate_output(map() | Jido.Action.Output.t()) ::
                  {:ok, map() | Jido.Action.Output.t()}
                  | {:error, Jido.Action.Error.InvalidInputError.t()}
          def validate_output(output), do: Action.validate_output_for(output, __MODULE__)

          @doc """
          Executes the Action with the given parameters and context.

          The `run/2` function must be implemented in the module using Jido.Action.
          """
          @impl Jido.Action
          @spec run(map(), map()) :: Jido.Action.result()
          def run(params, context) do
            "run/2 must be implemented in your Action"
            |> Error.config_error()
            |> then(&{:error, &1})
          end

          defoverridable run: 2

        {:error, errors} ->
          message =
            if is_list(errors) do
              "Action configuration validation failed:\n" <> Zoi.prettify_errors(errors)
            else
              "Action configuration validation failed: #{inspect(errors)}"
            end

          raise CompileError, description: message, file: __ENV__.file, line: __ENV__.line
      end
    end
  end

  @doc """
  Executes the Action with the given parameters and context.

  This callback must be implemented by modules using `Jido.Action`.

  ## Parameters

  - `params`: A map of validated input parameters.
  - `context`: A map that contains caller-owned execution data.

  ## Returns

  - `{:ok, result}` where `result` is a map containing the action's output.
  - `{:ok, result, extras}` where `result` is a map and `extras` is additional data (e.g., directives).
  - `{:ok, output}` where `output` is an explicit `Jido.Action.Output` envelope for raw, stream, batch, or opaque success values.
  - `{:ok, output, extras}` where `output` is an explicit `Jido.Action.Output` envelope and `extras` is additional data.
  - `{:error, reason}` where `reason` describes why the action failed.
  - `{:error, reason, extras}` where `extras` is additional data (e.g., directives).

  Extras are delivered only to direct action or instruction callers. When an
  action runs as a `Jido.Flow` node, flow execution discards extras and uses only
  the action output or error reason.
  """
  @callback run(params :: map(), context :: map()) :: result()

  defp validate_data(schema, data, context, module) do
    Validation.open_validate(schema, data, %{
      context: context,
      module: module
    })
  end

  defp validate_action_map(value, _context, _module) when is_map(value), do: {:ok, value}

  defp validate_action_map(value, context, module) do
    {:error,
     Error.validation_error("#{context} validation must return a map", %{
       context: context,
       module: module,
       value: value
     })}
  end

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
