defmodule Jido.Flow.DSL.ModuleCompiler do
  @moduledoc false

  alias Jido.Flow.DSL.{Lowerer, MacroSupport}
  alias Jido.Flow.Component

  @doc false
  defmacro __using__(opts_ast) do
    module_compiler = __MODULE__

    quote location: :keep do
      @behaviour Jido.Action
      @behaviour Jido.Executable
      use Jido.Flow.DSL
      @before_compile Jido.Flow.DSL.ModuleCompiler
      @on_definition Jido.Flow.DSL.ModuleCompiler
      unquote(module_compiler).reserve_function!(__ENV__, {:step_action, 1})

      {validated_opts, stored_schema, stored_output_schema} =
        unquote(module_compiler).prepare_config!(unquote(opts_ast), __ENV__)

      Module.put_attribute(__MODULE__, :__jido_flow_schema__, stored_schema)
      Module.put_attribute(__MODULE__, :__jido_flow_output_schema__, stored_output_schema)
      Module.put_attribute(__MODULE__, :__jido_schema__, stored_schema)
      Module.put_attribute(__MODULE__, :__jido_output_schema__, stored_output_schema)

      @__jido_flow_opts__ Map.drop(validated_opts, [:schema, :output_schema])

      @doc "Returns the Flow name."
      @spec name() :: String.t()
      def name, do: @__jido_flow_opts__[:name]

      @doc "Returns the Flow description."
      @spec description() :: String.t() | nil
      def description, do: @__jido_flow_opts__[:description]

      @doc "Returns the Flow input schema."
      @spec schema() :: Jido.Action.schema()
      def schema, do: @__jido_schema__

      @doc "Returns the Flow output schema."
      @spec output_schema() :: Jido.Action.schema()
      def output_schema, do: @__jido_output_schema__

      @doc "Validates Flow input parameters."
      @spec validate_params(map()) ::
              {:ok, map()} | {:error, Jido.Action.Error.InvalidInputError.t()}
      def validate_params(params), do: Jido.Action.validate_params_for(params, __MODULE__)

      @doc "Validates a Flow output value."
      @spec validate_output(map() | Jido.Action.Output.t()) ::
              {:ok, map() | Jido.Action.Output.t()}
              | {:error, Jido.Action.Error.InvalidInputError.t()}
      def validate_output(output), do: Jido.Action.validate_output_for(output, __MODULE__)

      @doc false
      @spec __jido_executable__() :: Jido.Executable.t()
      def __jido_executable__()

      @doc "Returns the canonical Flow data for this module."
      @spec flow() :: Jido.Flow.t()
      def flow()

      @doc """
      Returns the Action target of a named Step.

      Accepts a string or atom name. Raises `ArgumentError` for invalid names,
      unknown names, and non-Step components, including Subflows. The result
      does not include the original Step's params, dependencies, or metadata.

      Works for inline and explicit Action-backed Steps. Call it after this
      Flow module has compiled, not from its unfinished DSL block. Lookup
      does not run the body or create atoms. Supply new Step fields when
      reusing the target through Builder or direct constructors. For stored
      JSON, register the target with an application-owned Action identifier
      and register the required parameter atom keys.

      Deploy the owning module and generated Actions together. The target
      can remain unchanged after a body edit; it is not a code version.
      """
      @spec step_action(String.t() | atom()) :: module()
      @__jido_flow_generated_definition__ {:step_action, 1}
      def step_action(name)
      Module.delete_attribute(__MODULE__, :__jido_flow_generated_definition__)

      @doc false
      @spec __jido_flow_source_map__() :: Jido.Flow.Compiled.source_map()
      def __jido_flow_source_map__()

      @doc "Compiles this module's canonical Flow into a Runic workflow."
      @spec compiled() :: Jido.Flow.Compiled.t()
      def compiled()

      @doc "Runs this Flow with the given parameters and context."
      @spec run(map(), map()) :: Jido.Action.result()
      def run(params, context)
    end
  end

  @doc false
  @spec register_step!(term(), Macro.Env.t()) :: String.t()
  def register_step!(value, env) do
    name =
      case Component.name(value) do
        {:ok, name} -> name
        {:error, error} -> MacroSupport.compile_error!(env, Exception.message(error))
      end

    names = Module.get_attribute(env.module, :__jido_flow_step_names__) || MapSet.new()

    if MapSet.member?(names, name) do
      MacroSupport.compile_error!(env, "duplicate Step name: #{inspect(name)}")
    end

    Module.put_attribute(env.module, :__jido_flow_step_names__, MapSet.put(names, name))
    name
  end

  @doc false
  @spec reserve_function!(Macro.Env.t(), {atom(), non_neg_integer()}) :: :ok
  def reserve_function!(env, function) do
    if Module.defines?(env.module, function), do: reserved_function_error!(env, function)
    reserved = Module.get_attribute(env.module, :__jido_flow_reserved_functions__) || []
    Module.put_attribute(env.module, :__jido_flow_reserved_functions__, [function | reserved])
  end

  @doc false
  @spec __on_definition__(Macro.Env.t(), atom(), atom(), list(), list(), term()) :: :ok
  def __on_definition__(env, _kind, name, args, _guards, _body) do
    arity = length(args)
    defaults = Enum.count(args, &match?({:\\, _, [_, _]}, &1))
    reserved = Module.get_attribute(env.module, :__jido_flow_reserved_functions__) || []
    generated = Module.get_attribute(env.module, :__jido_flow_generated_definition__)

    for defined_arity <- (arity - defaults)..arity do
      function = {name, defined_arity}

      if function in reserved and generated != function do
        reserved_function_error!(env, function)
      end
    end

    :ok
  end

  @spec reserved_function_error!(Macro.Env.t(), {atom(), non_neg_integer()}) :: no_return()
  defp reserved_function_error!(env, {name, arity}) do
    MacroSupport.compile_error!(
      env,
      "reserved Flow function #{name}/#{arity} cannot have user clauses"
    )
  end

  @doc false
  @spec prepare_config!(term(), Macro.Env.t()) ::
          {map(), Jido.Action.schema(), Jido.Action.schema()} | no_return()
  def prepare_config!(raw_opts, env) do
    case Jido.Flow.__validate_config__(normalize_options(raw_opts)) do
      {:ok, validated_opts} ->
        stored_schema =
          Jido.Action.ensure_static_schema!(
            Map.get(validated_opts, :schema, []),
            :schema,
            env
          )

        stored_output_schema =
          Jido.Action.ensure_static_schema!(
            Map.get(validated_opts, :output_schema, []),
            :output_schema,
            env
          )

        {validated_opts, stored_schema, stored_output_schema}

      {:error, error} ->
        raise CompileError,
          description: "Flow configuration validation failed: #{Exception.message(error)}",
          file: env.file,
          line: env.line
    end
  end

  @doc false
  defmacro __before_compile__(env), do: before_compile(env)

  @doc false
  @spec before_compile(Macro.Env.t()) :: Macro.t()
  def before_compile(env) do
    opts = Module.get_attribute(env.module, :__jido_flow_opts__)
    schema = Module.get_attribute(env.module, :__jido_flow_schema__)
    output_schema = Module.get_attribute(env.module, :__jido_flow_output_schema__)

    {flow, source_map} = compile_flow!(env, opts, schema, output_schema)
    escaped_flow = Macro.escape(flow)
    escaped_source_map = Macro.escape(source_map)

    step_actions =
      for %Jido.Flow.Step{name: name, action: action} <- flow.components,
          into: %{},
          do: {name, action}

    quote generated: true do
      def __jido_executable__, do: Jido.Executable.flow(__MODULE__)
      def flow, do: unquote(escaped_flow)
      def __jido_flow_source_map__, do: unquote(escaped_source_map)

      @__jido_flow_generated_definition__ {:step_action, 1}
      def step_action(name) do
        with {:ok, normalized} <- Jido.Flow.Component.name(name),
             {:ok, action} <- Map.fetch(unquote(Macro.escape(step_actions)), normalized) do
          action
        else
          _ ->
            raise ArgumentError,
                  "expected an Action-backed Step name in #{inspect(__MODULE__)}, got: #{inspect(name)}"
        end
      end

      Module.delete_attribute(__MODULE__, :__jido_flow_generated_definition__)

      def compiled,
        do: Jido.Flow.compile!(flow(), source_map: __jido_flow_source_map__())

      @impl Jido.Action
      def run(params, context), do: Jido.Exec.run(__MODULE__, params, context)
    end
  end

  defp compile_flow!(env, opts, schema, output_schema) do
    source_map = Lowerer.source_map(env.module, env.file)

    case Lowerer.lower(env.module,
           name: opts[:name],
           description: opts[:description],
           schema: schema,
           output_schema: output_schema
         ) do
      {:ok, flow} ->
        ensure_targets_compiled(flow)
        {validate_executable!(flow, env, source_map), source_map}

      {:error, error} ->
        raise_compile_error!(env, Exception.message(error), error, source_map)
    end
  end

  defp ensure_targets_compiled(flow) do
    flow.components
    |> Enum.flat_map(&Component.target_modules/1)
    |> Enum.uniq()
    |> Enum.each(&Code.ensure_compiled/1)
  end

  defp validate_executable!(flow, env, source_map) do
    case Jido.Flow.validate_executable(flow) do
      {:ok, flow} ->
        flow

      {:error, error} ->
        raise_compile_error!(env, compile_error_message(error), error, source_map)
    end
  end

  @spec raise_compile_error!(
          Macro.Env.t(),
          String.t(),
          Exception.t(),
          Jido.Flow.Compiled.source_map()
        ) ::
          no_return()
  defp raise_compile_error!(env, description, error, source_map) do
    details = Map.get(error, :details, %{})

    raise CompileError,
      description: description,
      file: source_file(details, env),
      line: source_line(details, source_map, env)
  end

  defp source_file(%{file: file}, _env) when is_binary(file), do: file
  defp source_file(_details, env), do: env.file

  defp source_line(%{line: line}, _flow, _env) when is_integer(line) and line > 0, do: line

  defp source_line(details, source_map, env) when is_map(source_map) do
    case source_location(source_map, details) do
      %{line: line} when is_integer(line) and line > 0 -> line
      _location -> env.line
    end
  end

  defp source_location(source_map, details) do
    details
    |> source_paths()
    |> Enum.find_value(&Map.get(source_map, &1))
  end

  defp source_paths(%{component: component, field: :fallback}) do
    [[:components, component, :fallback], [:components, component]]
  end

  defp source_paths(%{component: component, field: field}) when is_binary(field) do
    [[:components, component, :options, field], [:components, component]]
  end

  defp source_paths(%{path: [:output | _rest]}), do: [[:output]]
  defp source_paths(%{component: component}), do: [[:components, component]]
  defp source_paths(%{node: component}), do: [[:components, component]]
  defp source_paths(_details), do: []

  defp compile_error_message(error) when is_exception(error) do
    message = Exception.message(error)
    details = Map.get(error, :details, %{})

    case {Map.fetch(details, :node), Map.fetch(details, :action)} do
      {{:ok, node}, {:ok, action}} ->
        "#{message} (node: #{inspect(node)}, action: #{inspect(action)})"

      _other ->
        message
    end
  end

  defp normalize_options(raw_opts) when is_list(raw_opts) do
    if Keyword.keyword?(raw_opts), do: Map.new(raw_opts), else: raw_opts
  end

  defp normalize_options(raw_opts), do: raw_opts
end
