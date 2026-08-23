defmodule Jido.Flow.DSL.ModuleCompiler do
  @moduledoc false

  alias Jido.Flow.DSL.Lowerer

  @doc false
  def using(opts_ast) do
    quote location: :keep do
      @behaviour Jido.Action
      use Jido.Flow.DSL
      @before_compile Jido.Flow.DSL.ModuleCompiler

      raw_opts = unquote(opts_ast)

      opts_map =
        if is_list(raw_opts) and Keyword.keyword?(raw_opts) do
          Map.new(raw_opts)
        else
          raw_opts
        end

      case Jido.Flow.__validate_config__(opts_map) do
        {:ok, validated_opts} ->
          stored_schema =
            Jido.Action.ensure_static_schema!(
              Map.get(validated_opts, :schema, []),
              :schema,
              __ENV__
            )

          stored_output_schema =
            Jido.Action.ensure_static_schema!(
              Map.get(validated_opts, :output_schema, []),
              :output_schema,
              __ENV__
            )

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

        {:error, error} ->
          raise CompileError,
            description: "Flow configuration validation failed: #{Exception.message(error)}",
            file: __ENV__.file,
            line: __ENV__.line
      end
    end
  end

  @doc false
  defmacro __before_compile__(env), do: before_compile(env)

  @doc false
  def before_compile(env) do
    opts = Module.get_attribute(env.module, :__jido_flow_opts__)
    schema = Module.get_attribute(env.module, :__jido_flow_schema__)
    output_schema = Module.get_attribute(env.module, :__jido_flow_output_schema__)

    flow = compile_flow!(env, opts, schema, output_schema)
    escaped_flow = Macro.escape(flow)

    quote do
      @doc false
      def __jido_flow__, do: true

      def flow, do: unquote(escaped_flow)
      def to_map(opts \\ []), do: Jido.Flow.to_map(flow(), opts)
      def to_stored_map(registry, opts \\ []), do: Jido.Flow.to_stored_map(flow(), registry, opts)
      def validate, do: Jido.Flow.validate(flow())
      def validate_executable, do: Jido.Flow.validate_executable(flow())
      def dependencies, do: Jido.Flow.dependencies(flow())
      def explain, do: Jido.Flow.explain(flow())
      def semantic_identity, do: Jido.Flow.semantic_identity(flow())
      def run(params, context), do: Jido.Exec.run(flow(), params, context)
    end
  end

  defp compile_flow!(env, opts, schema, output_schema) do
    case Lowerer.lower(env.module,
           name: opts[:name],
           description: opts[:description],
           schema: schema,
           output_schema: output_schema
         ) do
      {:ok, flow} ->
        validate_executable!(flow, env)

      {:error, error} ->
        raise_compile_error!(env, Exception.message(error))
    end
  end

  defp validate_executable!(flow, env) do
    case Jido.Flow.validate_executable(flow) do
      {:ok, flow} -> flow
      {:error, error} -> raise_compile_error!(env, compile_error_message(error))
    end
  end

  defp raise_compile_error!(env, description) do
    raise CompileError,
      description: description,
      file: env.file,
      line: env.line
  end

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
end
