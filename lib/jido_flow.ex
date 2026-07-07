defmodule Jido.Flow do
  @moduledoc """
  Canonical v4 Flow artifact.

  A Flow is a data artifact describing named action calls and a declared return
  reference. Authoring surfaces lower into this struct; execution is delegated
  through `Jido.Exec`.
  """

  alias Jido.Action
  alias Jido.Action.Error
  alias Jido.Flow.{Node, Ref}
  alias Jido.Instruction

  @schema Zoi.struct(
            __MODULE__,
            %{
              name: Zoi.string(description: "Flow name"),
              description: Zoi.string(description: "Flow description") |> Zoi.optional(),
              schema: Zoi.any(description: "Flow input schema") |> Zoi.default([]),
              output_schema: Zoi.any(description: "Flow output schema") |> Zoi.default([]),
              nodes: Zoi.list(Zoi.any(), description: "Canonical Flow nodes") |> Zoi.default([]),
              return: Zoi.any(description: "Declared return reference"),
              provenance: Zoi.map(description: "Non-semantic provenance") |> Zoi.default(%{})
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  defmacro __using__(opts_ast) do
    {schema_ast, output_schema_ast} =
      if is_list(opts_ast) do
        {Keyword.get(opts_ast, :schema), Keyword.get(opts_ast, :output_schema)}
      else
        {nil, nil}
      end

    quote location: :keep do
      @behaviour Jido.Action
      @before_compile Jido.Flow

      import Jido.Flow.DSL, only: [flow: 1]

      opts_map =
        if is_list(unquote(opts_ast)) and Keyword.keyword?(unquote(opts_ast)) do
          Map.new(unquote(opts_ast))
        else
          unquote(opts_ast)
        end

      case Jido.Flow.__validate_config__(opts_map) do
        {:ok, validated_opts} ->
          @__jido_flow_schema__ Map.get(validated_opts, :schema, [])
          @__jido_flow_output_schema__ Map.get(validated_opts, :output_schema, [])

          if unquote(is_nil(schema_ast)) do
            @__jido_schema__ Map.get(validated_opts, :schema, [])
          end

          if unquote(is_nil(output_schema_ast)) do
            @__jido_output_schema__ Map.get(validated_opts, :output_schema, [])
          end

          @__jido_flow_opts__ Map.drop(validated_opts, [:schema, :output_schema])

          def name, do: @__jido_flow_opts__[:name]
          def description, do: @__jido_flow_opts__[:description]

          if unquote(schema_ast) do
            def schema, do: unquote(schema_ast)
          else
            def schema, do: @__jido_schema__
          end

          if unquote(output_schema_ast) do
            def output_schema, do: unquote(output_schema_ast)
          else
            def output_schema, do: @__jido_output_schema__
          end

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

  defmacro __before_compile__(env) do
    opts = Module.get_attribute(env.module, :__jido_flow_opts__)
    schema = Module.get_attribute(env.module, :__jido_flow_schema__)
    output_schema = Module.get_attribute(env.module, :__jido_flow_output_schema__)
    operations = Module.get_attribute(env.module, :__jido_flow_operations__) || []

    syntax =
      Jido.Flow.Syntax.new(
        name: opts[:name],
        description: opts[:description],
        schema: schema,
        output_schema: output_schema
      )

    syntax = %{syntax | operations: operations}

    flow =
      case Jido.Flow.Syntax.Lowerer.lower(syntax) do
        {:ok, flow} ->
          case Jido.Flow.check(flow) do
            :ok ->
              flow

            {:error, error} ->
              raise CompileError,
                description: compile_error_message(error),
                file: env.file,
                line: env.line
          end

        {:error, error} ->
          raise CompileError,
            description: Exception.message(error),
            file: env.file,
            line: env.line
      end

    escaped_flow = Macro.escape(flow)

    quote do
      @doc false
      def __jido_flow__, do: true

      def flow, do: unquote(escaped_flow)
      def to_map(opts \\ []), do: Jido.Flow.to_map(flow(), opts)
      def compile, do: Jido.Flow.compile(flow())
      def run(params, context), do: Jido.Exec.run(flow(), params, context)
    end
  end

  @doc """
  Builds and validates a canonical Flow artifact.
  """
  @spec new(map() | keyword() | t()) :: {:ok, t()} | {:error, Exception.t()}
  def new(%__MODULE__{} = flow), do: validate(flow)
  def new(attrs) when is_list(attrs), do: attrs |> Map.new() |> new()

  def new(%{} = attrs) do
    with {:ok, name} <- validate_name(Map.get(attrs, :name)),
         {:ok, description} <- validate_description(Map.get(attrs, :description)),
         {:ok, schema} <- validate_schema(Map.get(attrs, :schema, []), "schema"),
         {:ok, output_schema} <-
           validate_schema(Map.get(attrs, :output_schema, []), "output_schema"),
         {:ok, nodes} <- normalize_nodes(Map.get(attrs, :nodes, [])),
         {:ok, return} <- validate_return(Map.get(attrs, :return)),
         {:ok, provenance} <- validate_provenance(Map.get(attrs, :provenance, %{})) do
      %__MODULE__{
        name: name,
        description: description,
        schema: schema,
        output_schema: output_schema,
        nodes: nodes,
        return: return,
        provenance: provenance
      }
      |> validate()
    end
  end

  def new(_attrs), do: {:error, Error.validation_error("flow configuration must be a map")}

  @doc """
  Builds a Flow artifact or raises on validation failure.
  """
  @spec new!(map() | keyword() | t()) :: t() | no_return()
  def new!(attrs) do
    case new(attrs) do
      {:ok, flow} -> flow
      {:error, error} when is_exception(error) -> raise error
    end
  end

  @doc """
  Converts a Flow artifact to its deterministic semantic map.

  Node order in the semantic map is dependency order with node-name tiebreaks;
  authoring order is not semantic and is preserved only on the Flow struct.
  Provenance is omitted by default because it does not participate in semantic
  equality.
  """
  @spec to_map(t(), keyword()) :: map()
  def to_map(%__MODULE__{} = flow, opts \\ []) do
    base = %{
      type: :flow,
      name: flow.name,
      description: flow.description,
      schema: flow.schema,
      output_schema: flow.output_schema,
      nodes: flow.nodes |> canonical_node_order() |> Enum.map(&Node.to_map(&1, opts)),
      return: Ref.to_map(flow.return)
    }

    if Keyword.get(opts, :provenance, false) do
      Map.put(base, :provenance, flow.provenance)
    else
      base
    end
  end

  defp canonical_node_order(nodes) do
    nodes_by_name = Map.new(nodes, fn node -> {node.name, node} end)
    remaining = Map.new(nodes, fn node -> {node.name, MapSet.new(node.deps)} end)

    nodes_by_name
    |> do_canonical_node_order(remaining, [])
    |> Enum.reverse()
  end

  defp do_canonical_node_order(_nodes_by_name, remaining, ordered)
       when map_size(remaining) == 0 do
    ordered
  end

  defp do_canonical_node_order(nodes_by_name, remaining, ordered) do
    ready =
      remaining
      |> Enum.filter(fn {_name, deps} -> MapSet.size(deps) == 0 end)
      |> Enum.map(fn {name, _deps} -> name end)
      |> Enum.sort_by(&node_name_sort_key/1)

    if ready == [] do
      remaining_nodes =
        remaining
        |> Map.keys()
        |> Enum.sort_by(&node_name_sort_key/1)
        |> Enum.map(&Map.fetch!(nodes_by_name, &1))

      Enum.reverse(remaining_nodes) ++ ordered
    else
      ready_set = MapSet.new(ready)

      remaining =
        remaining
        |> Map.drop(ready)
        |> Map.new(fn {name, deps} -> {name, MapSet.difference(deps, ready_set)} end)

      ready_nodes = Enum.map(ready, &Map.fetch!(nodes_by_name, &1))

      do_canonical_node_order(nodes_by_name, remaining, Enum.reverse(ready_nodes) ++ ordered)
    end
  end

  defp node_name_sort_key(name), do: to_string(name)

  @doc """
  Parses trusted developer Flow source into a canonical Flow artifact.
  """
  @spec parse(String.t(), map() | keyword()) :: {:ok, t()} | {:error, Exception.t()}
  def parse(source, opts \\ []), do: Jido.Flow.Parser.parse(source, opts)

  @doc """
  Compiles a Flow artifact into a Runic workflow for graph inspection.

  Executing this workflow directly resolves `input(...)` and `context(...)`
  references against empty maps. Use `Jido.Exec.run/3` to execute a Flow with
  runtime input and context.
  """
  @spec compile(t()) :: {:ok, Runic.Workflow.t()} | {:error, Exception.t()}
  def compile(%__MODULE__{} = flow), do: Jido.Flow.Compiler.compile(flow)

  @doc false
  @spec check(t()) :: :ok | {:error, Exception.t()}
  def check(%__MODULE__{} = flow), do: check_action_contracts(flow.nodes)

  @doc false
  @spec validate(t()) :: {:ok, t()} | {:error, Exception.t()}
  def validate(%__MODULE__{} = flow) do
    with :ok <- validate_duplicate_nodes(flow.nodes),
         :ok <- validate_known_result_refs(flow),
         flow = normalize_node_deps(flow),
         :ok <- validate_acyclic(flow.nodes) do
      {:ok, flow}
    end
  end

  @doc false
  @spec __validate_config__(map()) :: {:ok, map()} | {:error, Exception.t()}
  def __validate_config__(%{} = attrs) do
    with {:ok, name} <- validate_name(Map.get(attrs, :name)),
         {:ok, description} <- validate_description(Map.get(attrs, :description)),
         {:ok, schema} <- validate_schema(Map.get(attrs, :schema, []), "schema"),
         {:ok, output_schema} <-
           validate_schema(Map.get(attrs, :output_schema, []), "output_schema") do
      {:ok,
       %{
         name: name,
         description: description,
         schema: schema,
         output_schema: output_schema
       }}
    end
  end

  def __validate_config__(_attrs) do
    {:error, Error.validation_error("flow configuration must be a map")}
  end

  defp validate_name(name) when is_binary(name) do
    case Action.validate_name(name) do
      :ok -> {:ok, name}
      {:error, message} -> {:error, Error.validation_error(message)}
    end
  end

  defp validate_name(_name), do: {:error, Error.validation_error("flow name must be a string")}

  defp validate_description(nil), do: {:ok, nil}
  defp validate_description(description) when is_binary(description), do: {:ok, description}

  defp validate_description(_description) do
    {:error, Error.validation_error("flow description must be a string")}
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

  defp validate_schema(nil, _field), do: {:ok, []}

  defp validate_schema(schema, field) do
    case Action.validate_config_schema(schema) do
      :ok ->
        {:ok, schema}

      {:error, message} ->
        {:error, Error.validation_error("#{field} #{message}", %{field: field})}
    end
  end

  defp normalize_nodes(nodes) when is_list(nodes) do
    nodes
    |> Enum.reduce_while({:ok, []}, fn attrs, {:ok, acc} ->
      case Node.new(attrs) do
        {:ok, node} -> {:cont, {:ok, [node | acc]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, nodes} -> {:ok, Enum.reverse(nodes)}
      {:error, error} -> {:error, error}
    end
  end

  defp normalize_nodes(_nodes), do: {:error, Error.validation_error("flow nodes must be a list")}

  defp validate_return(%Ref{type: :result} = ref), do: {:ok, ref}

  defp validate_return(nil) do
    {:error, Error.validation_error("return ref is required")}
  end

  defp validate_return(_return) do
    {:error, Error.validation_error("return must be a result ref")}
  end

  defp validate_provenance(nil), do: {:ok, %{}}
  defp validate_provenance(provenance) when is_map(provenance), do: {:ok, provenance}

  defp validate_provenance(_provenance) do
    {:error, Error.validation_error("flow provenance must be a map")}
  end

  defp validate_duplicate_nodes(nodes) do
    nodes
    |> Enum.map(& &1.name)
    |> Enum.find(fn name -> Enum.count(nodes, &(&1.name == name)) > 1 end)
    |> case do
      nil ->
        :ok

      name ->
        {:error, Error.validation_error("duplicate step name: #{inspect(name)}", %{name: name})}
    end
  end

  defp check_action_contracts(nodes) do
    Enum.reduce_while(nodes, :ok, fn node, :ok ->
      case Instruction.validate_action_contract(node.action) do
        :ok ->
          {:cont, :ok}

        {:error, error} ->
          details =
            error.details
            |> Map.put(:node, node.name)
            |> Map.put(:action, node.action)

          {:halt, {:error, Error.validation_error(error.message, details)}}
      end
    end)
  end

  defp validate_known_result_refs(%__MODULE__{} = flow) do
    known = flow.nodes |> Enum.map(& &1.name) |> MapSet.new()

    cond do
      not MapSet.member?(known, flow.return.node) ->
        {:error,
         Error.validation_error(
           "return ref points to an unknown step: #{inspect(flow.return.node)}",
           %{
             node: flow.return.node,
             ref: Ref.to_map(flow.return)
           }
         )}

      true ->
        validate_node_result_refs(flow.nodes, known)
    end
  end

  defp validate_node_result_refs(nodes, known) do
    Enum.reduce_while(nodes, :ok, fn node, :ok ->
      missing = node |> Node.result_deps() |> Enum.reject(&MapSet.member?(known, &1))

      case missing do
        [] ->
          {:cont, :ok}

        [missing_node | _] ->
          {:halt,
           {:error,
            Error.validation_error(
              "node input points to an unknown step: #{inspect(missing_node)}",
              %{
                node: node.name,
                dependency: missing_node
              }
            )}}
      end
    end)
  end

  defp normalize_node_deps(%__MODULE__{} = flow) do
    nodes =
      Enum.map(flow.nodes, fn node ->
        %{node | deps: Node.result_deps(node)}
      end)

    %{flow | nodes: nodes}
  end

  defp validate_acyclic(nodes) do
    nodes
    |> Map.new(fn node -> {node.name, MapSet.new(node.deps)} end)
    |> validate_acyclic_remaining()
  end

  defp validate_acyclic_remaining(remaining) when map_size(remaining) == 0, do: :ok

  defp validate_acyclic_remaining(remaining) do
    ready =
      remaining
      |> Enum.filter(fn {_name, deps} -> MapSet.size(deps) == 0 end)
      |> Enum.map(fn {name, _deps} -> name end)

    if ready == [] do
      {:error,
       Error.validation_error("flow dependency graph contains a cycle", %{
         nodes: remaining |> Map.keys() |> Enum.sort()
       })}
    else
      ready_set = MapSet.new(ready)

      remaining
      |> Map.drop(ready)
      |> Map.new(fn {name, deps} -> {name, MapSet.difference(deps, ready_set)} end)
      |> validate_acyclic_remaining()
    end
  end
end
