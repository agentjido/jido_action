defmodule Jido.Flow.DSL.ModuleCompiler do
  @moduledoc false

  alias Jido.Flow.DSL.Lowerer
  alias Jido.Flow.Component

  @doc false
  def using(opts_ast) do
    module_compiler = __MODULE__

    quote location: :keep do
      @behaviour Jido.Action
      @behaviour Jido.Executable
      use Jido.Flow.DSL
      @before_compile Jido.Flow.DSL.ModuleCompiler

      {validated_opts, stored_schema, stored_output_schema} =
        unquote(module_compiler).prepare_config!(unquote(opts_ast), __ENV__)

      Module.put_attribute(__MODULE__, :__jido_flow_schema__, stored_schema)
      Module.put_attribute(__MODULE__, :__jido_flow_output_schema__, stored_output_schema)
      Module.put_attribute(__MODULE__, :__jido_schema__, stored_schema)
      Module.put_attribute(__MODULE__, :__jido_output_schema__, stored_output_schema)

      @__jido_flow_opts__ Map.drop(validated_opts, [:schema, :output_schema])

      def name, do: @__jido_flow_opts__[:name]
      def description, do: @__jido_flow_opts__[:description]

      def schema, do: @__jido_schema__
      def output_schema, do: @__jido_output_schema__

      def validate_params(params), do: Jido.Action.validate_params_for(params, __MODULE__)
      def validate_output(output), do: Jido.Action.validate_output_for(output, __MODULE__)
    end
  end

  @doc false
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
  def before_compile(env) do
    opts = Module.get_attribute(env.module, :__jido_flow_opts__)
    schema = Module.get_attribute(env.module, :__jido_flow_schema__)
    output_schema = Module.get_attribute(env.module, :__jido_flow_output_schema__)

    {flow, source_map} = compile_flow!(env, opts, schema, output_schema)
    escaped_flow = Macro.escape(flow)
    escaped_source_map = Macro.escape(source_map)

    quote do
      @doc false
      def __jido_executable__, do: Jido.Executable.flow(__MODULE__)

      def flow, do: unquote(escaped_flow)
      @doc false
      def __jido_flow_source_map__, do: unquote(escaped_source_map)

      def compiled,
        do: Jido.Flow.compile!(flow(), source_map: __jido_flow_source_map__())

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
        raise_compile_error!(env, Exception.message(error), error)
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

  @spec raise_compile_error!(Macro.Env.t(), String.t(), Exception.t()) :: no_return()
  defp raise_compile_error!(env, description, error) do
    raise_compile_error!(env, description, error, nil)
  end

  @spec raise_compile_error!(
          Macro.Env.t(),
          String.t(),
          Exception.t(),
          Jido.Flow.Compiled.source_map() | nil
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

  defp source_line(_details, _source_map, env), do: env.line

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

  defp source_paths(%{component: component}), do: [[:components, component]]
  defp source_paths(%{node: component}), do: [[:components, component]]
  defp source_paths(%{path: [:output | _rest]}), do: [[:output]]
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
