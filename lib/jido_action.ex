defmodule Jido.Action do
  @moduledoc """
  Defines a discrete, validated unit of functionality within the Jido system.

  Actions are defined at compile-time and provide a consistent interface for
  validating inputs, executing one unit of work, and handling results.

  ## Features

  - Compile-time configuration validation
  - Runtime input parameter validation
  - Consistent error handling and formatting

  ## Usage

  To define a new Action, use the `Jido.Action` behavior in your module:

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

  ## Callbacks

  Implementing modules must define the following callback:

  - `c:run/2`: Executes the main logic of the Action.

  ## Purity and Effects

  `Jido.Action` modules are reusable execution units. `c:run/2` may be pure or effectful depending on the job.

  Doing HTTP requests, database queries, file system work, or other I/O in `c:run/2` is acceptable when the action needs that result immediately to continue. If an effect should instead be owned by a runtime or integration layer, hand it off there rather than doing it inline.

  When actions are used inside `jido`, the purity guarantee belongs to the agent or strategy `cmd/2` boundary, not necessarily to each action the runtime executes behind that boundary.

  ## Error Handling

  Errors are wrapped in `Jido.Action.Error` structs for uniform error reporting across the system.

  ## Testing

  Actions can be tested directly by calling their `run/2` function with test parameters and context:

      defmodule WeatherActionTest do
        use ExUnit.Case

        test "gets weather for location" do
          params = %{location: "Portland"}
          context = %{}

          assert {:ok, result} = WeatherAction.run(params, context)
          assert is_map(result)
          assert result.temperature > 0
        end

        test "handles invalid location" do
          params = %{location: ""}
          context = %{}

          assert {:error, error} = WeatherAction.run(params, context)
          assert error.type == :validation_error
        end
      end

  `Jido.Exec` is reserved for Runic-backed flow execution. Direct action calls
  stay explicit:

      test "weather action validates explicitly" do
        {:ok, params} = WeatherAction.validate_params(%{location: "Seattle"})
        {:ok, result} = WeatherAction.run(params, %{})
        {:ok, result} = WeatherAction.validate_output(result)

        assert result.weather_data.temperature > 0
      end

  ## Parameter and Output Validation

  > **Note on Validation:** The validation process for Actions is intentionally open.
  > Only fields specified in the schema and output_schema are validated. Unspecified
  > fields are not validated, allowing callers to pass additional parameters without
  > causing validation errors.
  >
  > Output validation works the same way - only fields specified in the output_schema
  > are validated, allowing Actions to return additional data that may be used by
  > downstream Actions or systems.
  """

  alias Jido.Action.Error

  @max_action_name_bytes 256

  # Define Zoi schema for Action metadata
  @schema Zoi.struct(
            __MODULE__,
            %{
              name:
                Zoi.string(description: "The name of the Action")
                |> Zoi.refine({__MODULE__, :validate_name, []}),
              description: Zoi.string(description: "Description") |> Zoi.optional(),
              schema:
                Zoi.any(description: "Zoi schema for validating Action input")
                |> Zoi.default([]),
              output_schema:
                Zoi.any(description: "Zoi schema for validating Action output")
                |> Zoi.default([])
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @action_config_schema Zoi.object(%{
                          name:
                            Zoi.string(description: "The non-blank metadata name of the Action.")
                            |> Zoi.refine({__MODULE__, :validate_name, []}),
                          description:
                            Zoi.string(description: "A description of what the Action does.")
                            |> Zoi.optional(),
                          schema:
                            Zoi.any(
                              description:
                                "A Zoi schema for validating the Action's input parameters."
                            )
                            |> Zoi.refine({__MODULE__, :validate_config_schema, []})
                            |> Zoi.default([]),
                          output_schema:
                            Zoi.any(
                              description:
                                "A Zoi schema for validating the Action's output. Only specified fields are validated."
                            )
                            |> Zoi.refine({__MODULE__, :validate_config_schema, []})
                            |> Zoi.default([])
                        })

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
    if zoi_schema?(value) do
      :ok
    else
      {:error, "must be a Zoi schema"}
    end
  end

  @doc false
  @spec validate_params_for(map(), module()) ::
          {:ok, map()} | {:error, Error.InvalidInputError.t()}
  def validate_params_for(params, module) do
    validate_data(module.schema(), params, "Action", module)
  end

  @doc false
  @spec validate_output_for(map(), module()) ::
          {:ok, map()} | {:error, Error.InvalidInputError.t()}
  def validate_output_for(output, module) do
    validate_data(module.output_schema(), output, "Action output", module)
  end

  @validate_params_doc """
  Validates the input parameters for the Action.

  ## Examples

      iex> defmodule ExampleAction do
      ...>   use Jido.Action,
      ...>     name: "example_action",
      ...>     schema: Zoi.object(%{input: Zoi.string()})
      ...> end
      ...> ExampleAction.validate_params(%{input: "test"})
      {:ok, %{input: "test"}}

      iex> ExampleAction.validate_params(%{})
      {:error, "Validation failed"}

  """

  @validate_output_doc """
  Validates the output result for the Action.

  ## Examples

      iex> defmodule ExampleAction do
      ...>   use Jido.Action,
      ...>     name: "example_action",
      ...>     output_schema: Zoi.object(%{result: Zoi.string()})
      ...> end
      ...> ExampleAction.validate_output(%{result: "test", extra: "ignored"})
      {:ok, %{result: "test", extra: "ignored"}}

      iex> ExampleAction.validate_output(%{extra: "ignored"})
      {:error, "Validation failed"}

  """

  @doc """
  Defines a new Action module.

  This macro sets up the necessary structure and callbacks for a Action,
  including configuration validation and default implementations.

  ## Options

  - `name` (required) - The non-blank metadata name of the Action.
  - `description` (optional) - A description of what the Action does.
  - `schema` (optional, default: []) - A Zoi schema for validating the Action's input parameters.
  - `output_schema` (optional, default: []) - A Zoi schema for validating the Action's output. Only specified fields are validated.

  ## Examples

      defmodule MyAction do
        use Jido.Action,
          name: "my_action",
          description: "Performs a specific task",
          schema: Zoi.object(%{input: Zoi.string()})

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

    # Extract schema ASTs from the opts if it's a literal keyword list
    # This preserves closures for Zoi schemas defined inline or in module attributes
    {schema_ast, output_schema_ast} =
      if is_list(opts_ast) do
        {Keyword.get(opts_ast, :schema), Keyword.get(opts_ast, :output_schema)}
      else
        # For non-literal opts (e.g., variables from other macros), we can't extract the AST
        # The schemas will be stored in module attributes from the validated opts
        {nil, nil}
      end

    metadata_ast = action_metadata_ast(schema_ast, output_schema_ast)
    validation_ast = action_validation_ast(validate_params_doc, validate_output_doc)
    run_ast = action_run_ast()

    quote location: :keep do
      @behaviour Jido.Action
      @on_definition Jido.Action

      Module.register_attribute(__MODULE__, :jido_allow_nested_exec, persist: false)

      alias Jido.Action

      # Convert opts to map for Zoi validation (including nested keyword lists)
      opts_map =
        if is_list(unquote(opts_ast)) and Keyword.keyword?(unquote(opts_ast)) do
          Map.new(unquote(opts_ast))
        else
          unquote(opts_ast)
        end

      case Zoi.parse(unquote(escaped_schema), opts_map) do
        {:ok, validated_opts} ->
          # Convert Zoi struct to map for backward compatibility
          validated_opts =
            if is_struct(validated_opts),
              do: Map.from_struct(validated_opts),
              else: validated_opts

          # When schema_ast is nil (non-literal opts), store schemas in module attributes
          # Note: This will lose closures for Zoi schemas passed via variables,
          # but it's the only option when we can't access the AST
          if unquote(is_nil(schema_ast)) do
            @__jido_schema__ Map.get(validated_opts, :schema, [])
          end

          if unquote(is_nil(output_schema_ast)) do
            @__jido_output_schema__ Map.get(validated_opts, :output_schema, [])
          end

          # Store validated opts without schemas to avoid closure serialization
          @validated_opts Map.drop(validated_opts, [:schema, :output_schema])

          unquote(metadata_ast)
          unquote(validation_ast)
          unquote(run_ast)

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

  defp action_metadata_ast(schema_ast, output_schema_ast) do
    quote location: :keep do
      unquote(basic_metadata_functions_ast())
      unquote(schema_function_ast(schema_ast))
      unquote(output_schema_function_ast(output_schema_ast))
    end
  end

  defp basic_metadata_functions_ast do
    quote location: :keep do
      @doc "Returns the name of the Action."
      def name, do: @validated_opts[:name]

      @doc "Returns the description of the Action."
      def description, do: @validated_opts[:description]
    end
  end

  defp schema_function_ast(schema_ast) do
    quote location: :keep do
      @doc "Returns the input schema of the Action."
      if unquote(schema_ast) do
        def schema, do: unquote(schema_ast)
      else
        def schema, do: @__jido_schema__
      end
    end
  end

  defp output_schema_function_ast(output_schema_ast) do
    quote location: :keep do
      @doc "Returns the output schema of the Action."
      if unquote(output_schema_ast) do
        def output_schema, do: unquote(output_schema_ast)
      else
        def output_schema, do: @__jido_output_schema__
      end
    end
  end

  defp action_validation_ast(validate_params_doc, validate_output_doc) do
    quote location: :keep do
      @doc unquote(validate_params_doc)
      @spec validate_params(map()) :: {:ok, map()} | {:error, String.t()}
      def validate_params(params), do: Action.validate_params_for(params, __MODULE__)

      @doc unquote(validate_output_doc)
      @spec validate_output(map()) :: {:ok, map()} | {:error, String.t()}
      def validate_output(output), do: Action.validate_output_for(output, __MODULE__)
    end
  end

  defp action_run_ast do
    quote location: :keep do
      @doc """
      Executes the Action with the given parameters and context.

      The `run/2` function must be implemented in the module using Jido.Action.
      """
      # Note: @spec annotations are intentionally omitted from these default
      # implementations. The @callback declarations (below) define the type
      # contracts. Adding @spec here causes dialyzer `extra_range` warnings in
      # consumer modules that don't override these functions, because the spec
      # includes {:error, _} but the default only returns {:ok, _}.
      def run(params, context) do
        "run/2 must be implemented in in your Action"
        |> Error.config_error()
        |> then(&{:error, &1})
      end

      defoverridable run: 2
    end
  end

  @doc false
  def __on_definition__(env, :def, :run, args, _guards, body) when length(args) == 2 do
    if Module.get_attribute(env.module, :jido_allow_nested_exec) do
      :ok
    else
      body
      |> nested_exec_calls(env)
      |> Enum.each(&warn_nested_exec(env, &1))
    end
  end

  def __on_definition__(_env, _kind, _name, _args, _guards, _body), do: :ok

  defp nested_exec_calls(body, env) do
    {_body, calls} =
      Macro.prewalk(body, [], fn
        {{:., dot_meta, [target_ast, :run]}, call_meta, call_args} = node, acc
        when is_list(call_args) ->
          if expands_to_exec?(target_ast, env) do
            line = Keyword.get(call_meta, :line) || Keyword.get(dot_meta, :line) || env.line
            {node, [%{line: line} | acc]}
          else
            {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(calls)
  end

  defp expands_to_exec?(target_ast, env), do: Macro.expand(target_ast, env) == Jido.Exec

  defp warn_nested_exec(env, %{line: line}) do
    message = """
    nested Jido action execution inside #{inspect(env.module)}.run/2

    Calling Jido.Exec.run inside an action makes composition opaque.
    Keep actions as leaf nodes and move composition to Jido.Flow/Jido.Exec.

    Set @jido_allow_nested_exec true before run/2 if this action is intentionally an orchestrator.
    """

    IO.warn(message, [{env.module, :run, 2, [file: env.file, line: line]}])
  end

  @doc """
  Executes the Action with the given parameters and context.

  This callback must be implemented by modules using `Jido.Action`.

  ## Parameters

  - `params`: A map of validated input parameters.
  - `context`: A map containing any additional context for the .

  ## Returns

  - `{:ok, result}` where `result` is a map containing the action's output.
  - `{:ok, result, extras}` where `result` is a map and `extras` is additional data (e.g., directives).
  - `{:error, reason}` where `reason` describes why the action failed.
  - `{:error, reason, extras}` where `extras` is additional data (e.g., directives).
  """
  @callback run(params :: map(), context :: map()) ::
              {:ok, map()} | {:ok, map(), any()} | {:error, any()} | {:error, any(), any()}

  @doc """
  Raises an error indicating that Actions cannot be defined at runtime.

  This function exists to prevent misuse of the Action system, as Actions
  are designed to be defined at compile-time only.

  ## Returns

  Always returns `{:error, reason}` where `reason` is a config error.

  ## Examples

      iex> Jido.Action.new()
      {:error, %Jido.Action.Error{type: :config_error, message: "Actions should not be defined at runtime"}}

  """
  @spec new() :: {:error, Exception.t()}
  @spec new(map() | keyword()) :: {:error, Exception.t()}
  def new, do: new(%{})

  def new(_map_or_kwlist) do
    "Actions should not be defined at runtime"
    |> Error.config_error()
    |> then(&{:error, &1})
  end

  defp validate_data([], data, _context, _module), do: {:ok, data}

  defp validate_data(schema, data, context, module) do
    if zoi_schema?(schema) do
      {known_data, unknown_data} = split_known_and_unknown(data, schema)

      schema
      |> Zoi.parse(known_data)
      |> handle_validation_result(unknown_data, context, module)
    else
      {:error,
       Error.validation_error("Unsupported schema type", %{
         context: context,
         module: module
       })}
    end
  end

  defp handle_validation_result({:ok, validated}, unknown, _context, _module) do
    validated = if is_struct(validated), do: Map.from_struct(validated), else: validated
    {:ok, Map.merge(unknown, validated)}
  end

  defp handle_validation_result({:error, errors}, _unknown, context, module) do
    {:error, format_validation_errors(errors, context, module)}
  end

  defp split_known_and_unknown(data, schema) do
    Map.split(data, schema_keys(schema))
  end

  defp schema_keys(%{__struct__: Zoi.Types.Map, fields: fields}) when is_list(fields) do
    Keyword.keys(fields)
  end

  defp schema_keys(%{__struct__: Zoi.Types.Struct, fields: fields}) when is_list(fields) do
    Keyword.keys(fields)
  end

  defp schema_keys(_schema), do: []

  defp format_validation_errors(errors, context, module) do
    Error.validation_error(Zoi.prettify_errors(errors), %{
      context: context,
      module: module,
      errors: Enum.map(errors, &format_zoi_error/1)
    })
  end

  defp format_zoi_error(%{path: path, message: message} = error) do
    %{
      path: path,
      message: message,
      code: Map.get(error, :code)
    }
  end

  defp zoi_schema?(value), do: is_struct(value) && Zoi.Type.impl_for(value) != nil
end
