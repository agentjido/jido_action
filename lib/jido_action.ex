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

  Direct action calls stay explicit:

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

  alias Jido.Action.{Error, Output, Validation}

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
  @spec ensure_storable_schema!(term(), atom(), Macro.Env.t()) :: term() | no_return()
  def ensure_storable_schema!(schema, option, env) do
    Macro.escape(schema)
    schema
  rescue
    ArgumentError ->
      raise CompileError,
        description: "declare the closure-based #{inspect(option)} option inline",
        file: env.file,
        line: env.line
  end

  @doc false
  @spec validate_params_for(map(), module()) ::
          {:ok, map()} | {:error, Error.InvalidInputError.t()}
  def validate_params_for(params, module) do
    validate_data(module.schema(), params, "Action", module)
  end

  @doc false
  @spec validate_output_for(map() | Output.t(), module()) ::
          {:ok, map() | Output.t()} | {:error, Error.InvalidInputError.t()}
  def validate_output_for(%Output{} = output, _module), do: Output.validate(output)

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

    store_schema? = store_schema_value?(schema_ast, __CALLER__)
    store_output_schema? = store_schema_value?(output_schema_ast, __CALLER__)

    quote location: :keep do
      @behaviour Jido.Action

      alias Jido.Action

      # Convert opts to map for Zoi validation (including nested keyword lists)
      raw_opts = unquote(opts_ast)

      opts_map =
        if is_list(raw_opts) and Keyword.keyword?(raw_opts) do
          Map.new(raw_opts)
        else
          raw_opts
        end

      case Zoi.parse(unquote(escaped_schema), opts_map) do
        {:ok, validated_opts} ->
          # Convert Zoi struct to map for backward compatibility
          validated_opts =
            if is_struct(validated_opts),
              do: Map.from_struct(validated_opts),
              else: validated_opts

          if unquote(store_schema?) do
            stored_schema =
              Action.ensure_storable_schema!(
                Map.get(validated_opts, :schema, []),
                :schema,
                __ENV__
              )

            Module.put_attribute(__MODULE__, :__jido_schema__, stored_schema)
          end

          if unquote(store_output_schema?) do
            stored_output_schema =
              Action.ensure_storable_schema!(
                Map.get(validated_opts, :output_schema, []),
                :output_schema,
                __ENV__
              )

            Module.put_attribute(__MODULE__, :__jido_output_schema__, stored_output_schema)
          end

          # Store validated opts without schemas to avoid closure serialization
          @validated_opts Map.drop(validated_opts, [:schema, :output_schema])

          @doc "Returns the name of the Action."
          def name, do: @validated_opts[:name]

          @doc "Returns the description of the Action."
          def description, do: @validated_opts[:description]

          @doc "Returns the input schema of the Action."
          if unquote(store_schema?) do
            def schema, do: @__jido_schema__
          else
            def schema, do: unquote(schema_ast)
          end

          @doc "Returns the output schema of the Action."
          if unquote(store_output_schema?) do
            def output_schema, do: @__jido_output_schema__
          else
            def output_schema, do: unquote(output_schema_ast)
          end

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
  - `context`: A map containing any additional context for the .

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
  @callback run(params :: map(), context :: map()) ::
              {:ok, map() | Output.t()}
              | {:ok, map() | Output.t(), any()}
              | {:error, any()}
              | {:error, any(), any()}

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

  defp validate_data(schema, data, context, module) do
    Validation.open_validate(schema, data, %{
      context: context,
      module: module
    })
  end

  defp store_schema_value?(nil, _env), do: true
  defp store_schema_value?({:@, _meta, [_value]}, _env), do: true

  defp store_schema_value?(ast, env) do
    caller_variables = env |> Macro.Env.vars() |> MapSet.new()

    {_ast, store?} =
      Macro.prewalk(ast, false, fn
        {name, meta, context} = node, store?
        when is_atom(name) and is_list(meta) and is_atom(context) ->
          {node, store? or MapSet.member?(caller_variables, {name, context})}

        node, store? ->
          {node, store?}
      end)

    store?
  end
end
