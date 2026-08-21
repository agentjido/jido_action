defmodule Jido.Flow do
  @moduledoc """
  Canonical v4 Flow artifact.

  A Flow is a data artifact describing named action calls, ordered Choices,
  Map fan-out, Reduce fan-in, and one declared return expression. Authoring
  surfaces lower into this struct; execution is delegated through `Jido.Exec`.

  A Choice is one Flow node. It evaluates data-only conditions in authored
  order, runs the first matching target, and uses a required routing fallback
  when no option matches.

  Flow nodes consume only an action's output or error reason. Action extras from
  `Jido.Action.run/2` are an instruction-path delivery channel and are discarded
  during flow execution.
  """

  alias Jido.Action
  alias Jido.Action.Error
  alias Jido.Flow.Element
  alias Jido.Flow.MapCodec
  alias Jido.Flow.Node

  @module_config_keys [:name, :description, :schema, :output_schema]
  @artifact_config_keys @module_config_keys ++ [:nodes, :return, :provenance]

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
    quote location: :keep do
      @behaviour Jido.Action
      @before_compile Jido.Flow

      import Jido.Flow.DSL, only: [flow: 1]

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
      def dependencies, do: Jido.Flow.dependencies(flow())
      def explain, do: Jido.Flow.explain(flow())
      def semantic_identity, do: Jido.Flow.semantic_identity(flow())
      def run(params, context), do: Jido.Exec.run(flow(), params, context)
    end
  end

  @doc """
  Builds and validates a canonical Flow artifact.
  """
  @spec new(map() | keyword() | t()) :: {:ok, t()} | {:error, Exception.t()}
  def new(%__MODULE__{} = flow), do: flow |> Map.from_struct() |> new()
  def new(attrs) when is_list(attrs), do: attrs |> Map.new() |> new()

  def new(%{} = attrs) do
    with :ok <- validate_known_keys(attrs, @artifact_config_keys),
         {:ok, name} <- validate_name(Map.get(attrs, :name)),
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
    ordered_nodes = canonical_node_order(flow.nodes)

    case Keyword.get(opts, :format, :semantic) do
      :semantic ->
        MapCodec.to_semantic_map(flow, ordered_nodes, opts)

      :stored ->
        MapCodec.to_stored_map!(flow, ordered_nodes, opts)

      format ->
        raise Error.validation_error("unsupported flow map format: #{inspect(format)}", %{
                format: format
              })
    end
  end

  @doc """
  Loads a versioned Flow map into the current canonical Flow artifact.
  """
  @spec from_map(map(), map() | keyword()) :: {:ok, t()} | {:error, Exception.t()}
  def from_map(map, opts \\ []), do: MapCodec.from_map(map, opts)

  @doc false
  @spec canonical_nodes([Element.t()]) :: [Element.t()]
  def canonical_nodes(nodes), do: canonical_node_order(nodes)

  defp inspection_projection(%__MODULE__{} = flow) do
    with {:ok, flow} <- validate(flow) do
      nodes = canonical_nodes(flow.nodes)

      dependencies =
        Map.new(nodes, fn node ->
          {Element.name(node), Element.deps(node) |> Enum.sort()}
        end)

      edges =
        nodes
        |> Enum.flat_map(fn node ->
          Enum.map(Element.deps(node), fn predecessor ->
            %{from: predecessor, to: Element.name(node)}
          end)
        end)
        |> Enum.sort_by(&{&1.from, &1.to})

      semantic_map = MapCodec.to_semantic_map(flow, nodes, [])

      {:ok,
       %{
         flow: flow,
         nodes: Enum.map(nodes, &Element.to_map/1),
         dependencies: dependencies,
         edges: edges,
         identity: Jido.Flow.Identity.identity(semantic_map)
       }}
    end
  end

  defp invalid_inspection_subject(value) do
    {:error, Error.validation_error("expected a Jido.Flow artifact", %{value: value})}
  end

  defp canonical_node_order(nodes) do
    sorted_nodes =
      nodes
      |> Map.new(fn node -> {Element.name(node), node} end)
      |> Map.values()
      |> Enum.sort_by(fn node -> node |> Element.name() |> node_name_sort_key() end)

    %{levels: levels, max_level: max_level, remaining: remaining} =
      traverse_dependency_graph(sorted_nodes)

    blocked = MapSet.new(remaining)

    nodes_by_level =
      sorted_nodes
      |> Enum.reject(&MapSet.member?(blocked, Element.name(&1)))
      |> Enum.group_by(&Map.fetch!(levels, Element.name(&1)))

    ordered_nodes =
      if max_level < 0 do
        []
      else
        Enum.flat_map(0..max_level, fn level ->
          Map.get(nodes_by_level, level, [])
        end)
      end

    blocked_nodes = Enum.filter(sorted_nodes, &MapSet.member?(blocked, Element.name(&1)))

    ordered_nodes ++ blocked_nodes
  end

  defp node_name_sort_key(name), do: to_string(name)

  @doc """
  Parses trusted developer Flow source into a canonical Flow artifact.
  """
  @spec parse(String.t(), map() | keyword()) :: {:ok, t()} | {:error, Exception.t()}
  def parse(source, opts \\ []), do: Jido.Flow.Parser.parse(source, opts)

  @doc """
  Compiles a Flow artifact into a Runic workflow for graph inspection.

  The workflow contains inert node markers. It does not execute Action work or
  resolve runtime input and context. Use `Jido.Exec.run/3` to execute a Flow.
  """
  @spec compile(t()) :: {:ok, Runic.Workflow.t()} | {:error, Exception.t()}
  def compile(%__MODULE__{} = flow), do: Jido.Flow.Compiler.compile(flow)

  @doc """
  Returns the direct canonical predecessors for every Flow node.
  """
  @spec dependencies(t()) ::
          {:ok, %{String.t() => [String.t()]}} | {:error, Error.InvalidInputError.t()}
  def dependencies(%__MODULE__{} = flow) do
    with {:ok, projection} <- inspection_projection(flow) do
      {:ok, projection.dependencies}
    end
  end

  def dependencies(value), do: invalid_inspection_subject(value)

  @doc """
  Returns the versioned canonical inspection data for a Flow.
  """
  @spec explain(t()) :: {:ok, map()} | {:error, Error.InvalidInputError.t()}
  def explain(%__MODULE__{} = flow) do
    with {:ok, projection} <- inspection_projection(flow) do
      {:ok,
       %{
         version: 1,
         kind: :flow,
         name: projection.flow.name,
         description: projection.flow.description,
         schema: projection.flow.schema,
         output_schema: projection.flow.output_schema,
         nodes: projection.nodes,
         dependencies: projection.dependencies,
         edges: projection.edges,
         return: Node.expression_to_map(projection.flow.return),
         identity: projection.identity
       }}
    end
  end

  def explain(value), do: invalid_inspection_subject(value)

  @doc """
  Returns the deterministic SHA-256 and UUIDv8 identity for a Flow.
  """
  @spec semantic_identity(t()) :: {:ok, map()} | {:error, Error.InvalidInputError.t()}
  def semantic_identity(%__MODULE__{} = flow) do
    with {:ok, projection} <- inspection_projection(flow) do
      {:ok, projection.identity}
    end
  end

  def semantic_identity(value), do: invalid_inspection_subject(value)

  @doc false
  @spec check(t()) :: :ok | {:error, Exception.t()}
  def check(%__MODULE__{} = flow), do: check_action_contracts(flow.nodes)

  @doc false
  @spec validate(t()) :: {:ok, t()} | {:error, Exception.t()}
  def validate(%__MODULE__{} = flow) do
    with {:ok, name} <- validate_name(flow.name),
         {:ok, description} <- validate_description(flow.description),
         {:ok, schema} <- validate_schema(flow.schema, "schema"),
         {:ok, output_schema} <- validate_schema(flow.output_schema, "output_schema"),
         {:ok, nodes} <- normalize_nodes(flow.nodes),
         {:ok, return} <- validate_return(flow.return),
         {:ok, provenance} <- validate_provenance(flow.provenance),
         flow = %{
           flow
           | name: name,
             description: description,
             schema: schema,
             output_schema: output_schema,
             nodes: nodes,
             return: return,
             provenance: provenance
         },
         :ok <- validate_static_semantic_data(flow),
         :ok <- validate_duplicate_nodes(flow.nodes),
         :ok <- validate_known_result_refs(flow),
         flow = normalize_node_deps(flow),
         :ok <- validate_acyclic(flow.nodes) do
      {:ok, flow}
    end
  end

  @doc false
  @spec __validate_config__(map()) :: {:ok, map()} | {:error, Exception.t()}
  def __validate_config__(%{} = attrs) do
    with :ok <- validate_known_keys(attrs, @module_config_keys),
         {:ok, name} <- validate_name(Map.get(attrs, :name)),
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
    with :ok <- validate_static_schema(schema),
         :ok <- Action.validate_action_schema(schema) do
      {:ok, schema}
    else
      {:error, message} ->
        {:error, Error.validation_error("#{field} #{message}", %{field: field})}
    end
  end

  defp validate_static_schema(schema) do
    case Action.validate_static_data(schema) do
      :ok -> :ok
      {:error, message} -> {:error, "must be static module data; #{message}"}
    end
  end

  defp validate_known_keys(attrs, allowed) do
    case attrs |> Map.keys() |> Enum.find(&(&1 not in allowed)) do
      nil ->
        :ok

      key ->
        {:error,
         Error.validation_error("unknown Flow configuration key: #{inspect(key)}", %{key: key})}
    end
  end

  defp validate_static_semantic_data(flow) do
    semantic_data = %{
      name: flow.name,
      description: flow.description,
      nodes: Enum.map(flow.nodes, &Element.semantic_data/1),
      return: flow.return
    }

    case Action.validate_static_data(semantic_data) do
      :ok ->
        :ok

      {:error, reason} ->
        {:error,
         Error.validation_error("Flow semantic data must be static module data; #{reason}", %{
           field: "semantic"
         })}
    end
  end

  defp normalize_nodes(nodes) when is_list(nodes) do
    nodes
    |> Enum.reduce_while({:ok, []}, fn attrs, {:ok, acc} ->
      case Element.new(attrs) do
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

  defp validate_return(nil) do
    {:error, Error.validation_error("return ref is required")}
  end

  defp validate_return(return) do
    with {:ok, return} <- Node.normalize_expression(return),
         :ok <- Node.validate_expression(return),
         :ok <- validate_return_has_result_ref(return) do
      {:ok, return}
    end
  end

  defp validate_return_has_result_ref(return) do
    case Node.collect_result_refs(return) do
      [] -> {:error, Error.validation_error("return must reference at least one step result")}
      _refs -> :ok
    end
  end

  defp validate_provenance(nil), do: {:ok, %{}}
  defp validate_provenance(provenance) when is_map(provenance), do: {:ok, provenance}

  defp validate_provenance(_provenance) do
    {:error, Error.validation_error("flow provenance must be a map")}
  end

  defp validate_duplicate_nodes(nodes) do
    names = Enum.map(nodes, &Element.name/1)
    frequencies = Enum.frequencies(names)

    names
    |> Enum.find(&(Map.fetch!(frequencies, &1) > 1))
    |> case do
      nil ->
        :ok

      name ->
        {:error, Error.validation_error("duplicate step name: #{inspect(name)}", %{name: name})}
    end
  end

  defp check_action_contracts(nodes) do
    Enum.reduce_while(nodes, :ok, fn node, :ok ->
      case Element.check(node) do
        :ok ->
          {:cont, :ok}

        {:error, error} ->
          {:halt, {:error, error}}
      end
    end)
  end

  defp validate_known_result_refs(%__MODULE__{} = flow) do
    known = flow.nodes |> Enum.map(&Element.name/1) |> MapSet.new()

    case flow.return
         |> Node.collect_result_refs()
         |> Enum.find(&(not MapSet.member?(known, &1))) do
      nil ->
        validate_node_result_refs(flow.nodes, known)

      missing_node ->
        {:error,
         Error.validation_error(
           "return ref points to an unknown step: #{inspect(missing_node)}",
           %{
             node: missing_node
           }
         )}
    end
  end

  defp validate_node_result_refs(nodes, known) do
    Enum.reduce_while(nodes, :ok, fn node, :ok ->
      missing = node |> Element.result_deps() |> Enum.reject(&MapSet.member?(known, &1))

      case missing do
        [] ->
          {:cont, :ok}

        [missing_node | _] ->
          {:halt,
           {:error,
            Error.validation_error(
              "node input points to an unknown step: #{inspect(missing_node)}",
              %{
                node: Element.name(node),
                dependency: missing_node
              }
            )}}
      end
    end)
  end

  defp normalize_node_deps(%__MODULE__{} = flow) do
    nodes =
      Enum.map(flow.nodes, fn node ->
        Element.put_deps(node, Element.result_deps(node))
      end)

    %{flow | nodes: nodes}
  end

  defp validate_acyclic(nodes) do
    case traverse_dependency_graph(nodes) do
      %{remaining: []} ->
        :ok

      %{remaining: remaining} ->
        {:error,
         Error.validation_error("flow dependency graph contains a cycle", %{
           nodes: Enum.sort(remaining)
         })}
    end
  end

  defp traverse_dependency_graph(nodes) do
    {indegrees, adjacency} =
      nodes
      |> Enum.reverse()
      |> Enum.reduce({%{}, %{}}, fn node, {indegrees, adjacency} ->
        name = Element.name(node)
        dependencies = node |> Element.deps() |> MapSet.new()

        adjacency =
          Enum.reduce(dependencies, adjacency, fn dependency, adjacency ->
            Map.update(adjacency, dependency, [name], &[name | &1])
          end)

        {Map.put(indegrees, name, MapSet.size(dependencies)), adjacency}
      end)

    ready =
      Enum.reduce(nodes, [], fn node, ready ->
        name = Element.name(node)

        if Map.fetch!(indegrees, name) == 0 do
          [name | ready]
        else
          ready
        end
      end)
      |> Enum.reverse()

    levels = Map.new(ready, &{&1, 0})

    max_level = if ready == [], do: -1, else: 0

    ready
    |> :queue.from_list()
    |> do_traverse_dependency_graph(indegrees, adjacency, levels, max_level)
  end

  defp do_traverse_dependency_graph(ready, indegrees, adjacency, levels, max_level) do
    case :queue.out(ready) do
      {:empty, _ready} ->
        %{levels: levels, max_level: max_level, remaining: Map.keys(indegrees)}

      {{:value, name}, ready} ->
        level = Map.fetch!(levels, name)
        indegrees = Map.delete(indegrees, name)

        {ready, indegrees, levels, max_level} =
          adjacency
          |> Map.get(name, [])
          |> Enum.reduce({ready, indegrees, levels, max_level}, fn dependent,
                                                                   {ready, indegrees, levels,
                                                                    max_level} ->
            next_indegree = Map.fetch!(indegrees, dependent) - 1
            dependent_level = max(Map.get(levels, dependent, 0), level + 1)
            levels = Map.put(levels, dependent, dependent_level)
            indegrees = Map.put(indegrees, dependent, next_indegree)

            {ready, max_level} =
              if next_indegree == 0 do
                {:queue.in(dependent, ready), max(max_level, dependent_level)}
              else
                {ready, max_level}
              end

            {ready, indegrees, levels, max_level}
          end)

        do_traverse_dependency_graph(ready, indegrees, adjacency, levels, max_level)
    end
  end
end
