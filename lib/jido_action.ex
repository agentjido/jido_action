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

  alias Jido.Action.{Error, Output, SchemaStore, Validation}

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
    if SchemaStore.portable?(schema), do: schema, else: raise(ArgumentError)
  rescue
    ArgumentError ->
      bindings_option =
        if option == :schema, do: :schema_bindings, else: :output_schema_bindings

      raise CompileError,
        description:
          "closure-based #{inspect(option)} requires literal #{inspect(bindings_option)}",
        file: env.file,
        line: env.line
  end

  @doc false
  @spec validate_action_config!(term(), Macro.Env.t()) :: map() | no_return()
  def validate_action_config!(opts, env) do
    case Zoi.parse(@action_config_schema, opts) do
      {:ok, validated_opts} ->
        if is_struct(validated_opts), do: Map.from_struct(validated_opts), else: validated_opts

      {:error, errors} ->
        message =
          if is_list(errors) do
            "Action configuration validation failed:\n" <> Zoi.prettify_errors(errors)
          else
            "Action configuration validation failed: #{inspect(errors)}"
          end

        raise CompileError, description: message, file: env.file, line: env.line
    end
  end

  @doc false
  @spec normalize_action_options!(term(), boolean(), Macro.Env.t()) :: map() | no_return()
  def normalize_action_options!(opts, literal_opts?, env) do
    opts_map =
      cond do
        is_list(opts) and Keyword.keyword?(opts) -> Map.new(opts)
        is_map(opts) -> opts
        true -> validate_action_config!(opts, env)
      end

    if not literal_opts? and
         (Map.has_key?(opts_map, :schema_bindings) or
            Map.has_key?(opts_map, :output_schema_bindings)) do
      raise CompileError,
        description: "schema bindings require literal Action options",
        file: env.file,
        line: env.line
    end

    opts_map
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
  - `schema_bindings` (optional) - Explicit portable values used by a deterministic closure-based input schema.
  - `output_schema` (optional, default: []) - A Zoi schema for validating the Action's output. Only specified fields are validated.
  - `output_schema_bindings` (optional) - Explicit portable values used by a deterministic closure-based output schema.

  Closure-based schemas must use a literal bindings option. Use an empty list
  when the schema has no external values. Bindings can contain portable data or
  external named function captures. The schema is built once for each module
  load, and later calls return that exact term. A fresh VM builds it again, so
  the schema expression must be deterministic.

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

      defmodule BoundedAction do
        minimum = 1

        use Jido.Action,
          name: "bounded_action",
          schema_bindings: [minimum: minimum],
          schema:
            Zoi.object(%{
              value:
                Zoi.integer()
                |> Zoi.refine(fn value ->
                  if value > minimum, do: :ok, else: {:error, "too small"}
                end)
            })
      end

  """
  defmacro __using__(opts_ast) do
    validate_params_doc = @validate_params_doc
    validate_output_doc = @validate_output_doc
    literal_opts? = is_list(opts_ast) and Keyword.keyword?(opts_ast)

    {raw_opts_ast, schema_spec, output_schema_spec} =
      if literal_opts? do
        schema_spec = schema_spec!(opts_ast, :schema, :schema_bindings, __CALLER__)

        output_schema_spec =
          schema_spec!(opts_ast, :output_schema, :output_schema_bindings, __CALLER__)

        raw_opts_ast =
          Keyword.drop(opts_ast, [
            :schema,
            :schema_bindings,
            :output_schema,
            :output_schema_bindings
          ])

        {
          raw_opts_ast,
          schema_spec,
          output_schema_spec
        }
      else
        {opts_ast, :dynamic, :dynamic}
      end

    schema_setup_ast = schema_setup_ast(schema_spec, :schema)
    output_schema_setup_ast = schema_setup_ast(output_schema_spec, :output_schema)
    schema_bound? = bound_schema_spec?(schema_spec)
    output_schema_bound? = bound_schema_spec?(output_schema_spec)

    quote location: :keep do
      @behaviour Jido.Action

      alias Jido.Action
      alias Jido.Action.SchemaStore

      raw_opts = unquote(raw_opts_ast)
      opts_map = Action.normalize_action_options!(raw_opts, unquote(literal_opts?), __ENV__)

      {schema_value, schema_recipe} = unquote(schema_setup_ast)
      {output_schema_value, output_schema_recipe} = unquote(output_schema_setup_ast)

      opts_map =
        opts_map
        |> Map.put(:schema, schema_value)
        |> Map.put(:output_schema, output_schema_value)

      validated_opts = Action.validate_action_config!(opts_map, __ENV__)
      validated_schema = Map.get(validated_opts, :schema, [])
      validated_output_schema = Map.get(validated_opts, :output_schema, [])

      if unquote(schema_bound?) do
        Module.put_attribute(__MODULE__, :__jido_schema_recipe__, schema_recipe)
      else
        stored_schema = Action.ensure_storable_schema!(validated_schema, :schema, __ENV__)
        Module.put_attribute(__MODULE__, :__jido_schema__, stored_schema)
      end

      if unquote(output_schema_bound?) do
        Module.put_attribute(
          __MODULE__,
          :__jido_output_schema_recipe__,
          output_schema_recipe
        )
      else
        stored_output_schema =
          Action.ensure_storable_schema!(validated_output_schema, :output_schema, __ENV__)

        Module.put_attribute(__MODULE__, :__jido_output_schema__, stored_output_schema)
      end

      @validated_opts Map.drop(validated_opts, [:schema, :output_schema])

      if unquote(schema_bound? or output_schema_bound?) do
        expected_recipes =
          [
            if(unquote(schema_bound?), do: schema_recipe),
            if(unquote(output_schema_bound?), do: output_schema_recipe)
          ]
          |> Enum.reject(&is_nil/1)

        SchemaStore.expect_load(__MODULE__, expected_recipes)
        @after_compile {SchemaStore, :verify_loaded}
        @before_compile Jido.Action
      end

      unquote(schema_builder_ast(schema_spec, :schema))
      unquote(schema_builder_ast(output_schema_spec, :output_schema))

      @doc "Returns the name of the Action."
      def name, do: @validated_opts[:name]

      @doc "Returns the description of the Action."
      def description, do: @validated_opts[:description]

      @doc "Returns the input schema of the Action."
      if unquote(schema_bound?) do
        def schema,
          do:
            SchemaStore.fetch!(
              __MODULE__,
              @__jido_schema_recipe__,
              &__jido_build_schema__/0
            )
      else
        def schema, do: @__jido_schema__
      end

      @doc "Returns the output schema of the Action."
      if unquote(output_schema_bound?) do
        def output_schema,
          do:
            SchemaStore.fetch!(
              __MODULE__,
              @__jido_output_schema_recipe__,
              &__jido_build_output_schema__/0
            )
      else
        def output_schema, do: @__jido_output_schema__
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
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    schema_recipe = Module.get_attribute(env.module, :__jido_schema_recipe__)
    output_schema_recipe = Module.get_attribute(env.module, :__jido_output_schema_recipe__)
    consumer_on_load = Module.get_attribute(env.module, :on_load)

    move_schema_verifier_first!(env.module)

    if Module.defines?(env.module, {:__jido_action_on_load__, 0}) do
      raise CompileError,
        description: "__jido_action_on_load__/0 is reserved by Jido.Action",
        file: env.file,
        line: env.line
    end

    if consumer_on_load, do: Module.delete_attribute(env.module, :on_load)

    consumer_on_load_ast = consumer_on_load_ast!(consumer_on_load, env)

    builders =
      [
        if(schema_recipe,
          do:
            quote(
              generated: true,
              do: {@__jido_schema_recipe__, &__jido_build_schema__/0}
            )
        ),
        if(output_schema_recipe,
          do:
            quote(
              generated: true,
              do: {@__jido_output_schema_recipe__, &__jido_build_output_schema__/0}
            )
        )
      ]
      |> Enum.reject(&is_nil/1)

    quote generated: true do
      @on_load :__jido_action_on_load__

      defp __jido_action_on_load__ do
        Jido.Action.SchemaStore.load!(
          __MODULE__,
          [unquote_splicing(builders)],
          fn -> unquote(consumer_on_load_ast) end
        )
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

  defp schema_spec!(opts_ast, option, bindings_option, env) do
    source? = Keyword.has_key?(opts_ast, option)
    bindings? = Keyword.has_key?(opts_ast, bindings_option)

    cond do
      bindings? and not source? ->
        raise CompileError,
          description: "#{inspect(bindings_option)} requires #{inspect(option)}",
          file: env.file,
          line: env.line

      bindings? ->
        source = opts_ast |> Keyword.get_values(option) |> List.last()
        bindings = opts_ast |> Keyword.get_values(bindings_option) |> List.last()
        validate_bindings_ast!(bindings, bindings_option, env)

        source =
          SchemaStore.prepare_source!(option, source, Keyword.keys(bindings), env)

        generation = :crypto.strong_rand_bytes(16)
        {:bound, source, bindings, generation}

      source? ->
        {:inline, opts_ast |> Keyword.get_values(option) |> List.last()}

      true ->
        :default
    end
  end

  defp validate_bindings_ast!(bindings, bindings_option, env) do
    unless is_list(bindings) and Keyword.keyword?(bindings) do
      raise CompileError,
        description: "#{inspect(bindings_option)} must be a literal keyword list",
        file: env.file,
        line: env.line
    end

    names = Keyword.keys(bindings)

    if Enum.uniq(names) != names do
      raise CompileError,
        description: "#{inspect(bindings_option)} cannot contain duplicate names",
        file: env.file,
        line: env.line
    end
  end

  defp schema_setup_ast(:default, _option) do
    quote generated: true do
      {[], nil}
    end
  end

  defp schema_setup_ast(:dynamic, option) do
    quote generated: true do
      {Map.get(opts_map, unquote(option), []), nil}
    end
  end

  defp schema_setup_ast({:inline, source}, _option) do
    quote generated: true do
      {unquote(source), nil}
    end
  end

  defp schema_setup_ast({:bound, _source, bindings, generation}, option) do
    binding_values = Macro.unique_var(:binding_values, __MODULE__)

    quote generated: true do
      unquote(binding_values) = unquote(bindings)

      recipe =
        SchemaStore.recipe!(
          unquote(option),
          unquote(binding_values),
          unquote(generation),
          __ENV__
        )

      {[], recipe}
    end
  end

  defp schema_builder_ast({:bound, source, bindings, _generation}, option) do
    binding_values = Macro.unique_var(:binding_values, __MODULE__)

    recipe_attribute =
      if option == :schema, do: :__jido_schema_recipe__, else: :__jido_output_schema_recipe__

    builder =
      if option == :schema, do: :__jido_build_schema__, else: :__jido_build_output_schema__

    recipe_attribute_ast =
      {:@, [generated: true], [{recipe_attribute, [generated: true], nil}]}

    assignments =
      Enum.map(bindings, fn {name, _value_ast} ->
        variable = Macro.var(name, nil)

        quote generated: true do
          unquote(variable) = Keyword.fetch!(unquote(binding_values), unquote(name))
        end
      end)

    quote generated: true do
      defp unquote(builder)() do
        unquote(binding_values) = unquote(recipe_attribute_ast).bindings
        unquote_splicing(assignments)
        unquote(source)
      end
    end
  end

  defp schema_builder_ast(_spec, _option), do: quote(generated: true, do: nil)

  defp consumer_on_load_ast!(nil, _env), do: quote(generated: true, do: :ok)

  defp consumer_on_load_ast!({function, 0}, _env) when is_atom(function) do
    {function, [generated: true], []}
  end

  defp consumer_on_load_ast!(callback, env) do
    raise CompileError,
      description: "unsupported consumer @on_load callback: #{inspect(callback)}",
      file: env.file,
      line: env.line
  end

  defp move_schema_verifier_first!(module) do
    verifier = {SchemaStore, :verify_loaded}

    callbacks =
      module
      |> Module.get_attribute(:after_compile)
      |> List.wrap()
      |> Enum.reject(&(&1 == verifier))
      |> Kernel.++([verifier])

    Module.delete_attribute(module, :after_compile)

    callbacks
    |> Enum.reverse()
    |> Enum.each(&Module.put_attribute(module, :after_compile, &1))
  end

  defp bound_schema_spec?({:bound, _source, _bindings, _generation}), do: true
  defp bound_schema_spec?(_spec), do: false

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
end
