defmodule Jido.Flow do
  @moduledoc """
  Defines the canonical Jido Flow artifact and compile-time authoring DSL.

  A Flow is a data artifact describing named Action calls, ordered Choices,
  Map fan-out, Reduce fan-in, bounded Iterate nodes, and one output expression.
  Execution is delegated through `Jido.Exec`.

  Use the compile-time Spark DSL as the primary developer authoring surface:

      defmodule MyApp.ProcessOrder do
        use Jido.Flow, name: "process_order"

        flow do
          step "load",
            action: MyApp.LoadOrder,
            params: %{id: input(:id)}

          step "save",
            action: MyApp.SaveOrder,
            params: %{order: result("load")}
        end
      end

  The last node is the output when an explicit `output` declaration is absent.
  Result references and `after:` fields define dependencies. Source order does
  not add execution dependencies.

  Use `Jido.Flow.Builder` for runtime construction. Use `to_stored_map/3` and
  `from_stored_map/2` with a trusted `Jido.Flow.Registry` for versioned storage.
  There is no runtime parser for DSL source.

  A Choice is one Flow node. It evaluates data-only conditions in authored
  order, runs the first matching target, and uses a required routing fallback
  when no option matches.

  Flow nodes consume only an Action output or error reason. Extra values from
  an Action callback are returned only to direct Action or Instruction callers.
  Flow execution discards them.
  """

  alias Jido.Action.Error
  alias Jido.Flow.Element
  alias Jido.Flow.Graph
  alias Jido.Flow.Identity
  alias Jido.Flow.Inspection
  alias Jido.Flow.MapCodec
  alias Jido.Flow.Validation

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
      use Jido.Flow.DSL
      @before_compile Jido.Flow

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

    flow =
      case Jido.Flow.DSL.Lowerer.lower(env.module,
             name: opts[:name],
             description: opts[:description],
             schema: schema,
             output_schema: output_schema
           ) do
        {:ok, flow} ->
          case Jido.Flow.validate_executable(flow) do
            {:ok, flow} ->
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
      def to_stored_map(registry, opts \\ []), do: Jido.Flow.to_stored_map(flow(), registry, opts)
      def validate, do: Jido.Flow.validate(flow())
      def validate_executable, do: Jido.Flow.validate_executable(flow())
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

  def new(attrs) do
    with {:ok, attrs} <- Validation.new(attrs) do
      {:ok, struct!(__MODULE__, attrs)}
    end
  end

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
  equality. Use `to_stored_map/3` for database storage.
  """
  @spec to_map(t(), keyword()) :: map()
  def to_map(%__MODULE__{} = flow, opts \\ []) do
    ordered_nodes = canonical_node_order(flow.nodes)
    MapCodec.to_semantic_map(flow, ordered_nodes, opts)
  end

  @doc """
  Validates and converts a Flow to the versioned stored-map format.

  The Registry supplies stable identifiers for every Action and schema in the
  Flow. Stored data contains no module names or schema values. The only option
  is `provenance: true`.
  """
  @spec to_stored_map(t(), Jido.Flow.Registry.t(), keyword()) ::
          {:ok, map()} | {:error, Error.InvalidInputError.t()}
  def to_stored_map(flow, registry, opts \\ [])

  def to_stored_map(%__MODULE__{} = flow, registry, opts) do
    with {:ok, flow} <- validate(flow) do
      MapCodec.to_stored_map(flow, canonical_node_order(flow.nodes), registry, opts)
    end
  end

  def to_stored_map(value, _registry, _opts), do: invalid_flow_subject(value)

  @doc """
  Loads a versioned stored map through a trusted host Registry.

  Loading validates the stored grammar, resolves stable identifiers, and uses
  the same canonical constructor as the Spark DSL and Builder. It does not
  create atoms or derive module names from stored data.
  """
  @spec from_stored_map(map(), Jido.Flow.Registry.t()) ::
          {:ok, t()} | {:error, Exception.t()}
  def from_stored_map(map, registry), do: MapCodec.from_stored_map(map, registry)

  @doc false
  @spec canonical_nodes([Element.t()]) :: [Element.t()]
  def canonical_nodes(nodes), do: canonical_node_order(nodes)

  defp invalid_flow_subject(value) do
    Validation.invalid_subject(value)
  end

  defp canonical_node_order(nodes), do: Graph.canonical_nodes(nodes)

  @doc """
  Returns the direct canonical predecessors for every Flow node.
  """
  @spec dependencies(t()) ::
          {:ok, %{String.t() => [String.t()]}} | {:error, Error.InvalidInputError.t()}
  def dependencies(%__MODULE__{} = flow) do
    with {:ok, flow} <- validate(flow) do
      Inspection.dependencies(flow, &inspection_identity/2)
    end
  end

  def dependencies(value), do: invalid_flow_subject(value)

  @doc """
  Returns the versioned canonical inspection data for a Flow.
  """
  @spec explain(t()) :: {:ok, map()} | {:error, Error.InvalidInputError.t()}
  def explain(%__MODULE__{} = flow) do
    with {:ok, flow} <- validate(flow) do
      Inspection.explain(flow, &inspection_identity/2)
    end
  end

  def explain(value), do: invalid_flow_subject(value)

  @doc """
  Returns the deterministic SHA-256 and UUIDv8 identity for a Flow.
  """
  @spec semantic_identity(t()) :: {:ok, map()} | {:error, Error.InvalidInputError.t()}
  def semantic_identity(%__MODULE__{} = flow) do
    with {:ok, flow} <- validate(flow) do
      Inspection.semantic_identity(flow, &inspection_identity/2)
    end
  end

  def semantic_identity(value), do: invalid_flow_subject(value)

  @doc """
  Validates and normalizes the canonical Flow structure.

  This function checks schemas, nodes, expressions, references, dependencies,
  and graph cycles. It is inert: it does not load or check Action targets. Use
  `validate_executable/1` when the Flow must be ready for execution.
  """
  @spec validate(t()) :: {:ok, t()} | {:error, Exception.t()}
  def validate(%__MODULE__{} = flow) do
    with {:ok, attrs} <- flow |> Map.from_struct() |> Validation.validate() do
      {:ok, struct!(__MODULE__, attrs)}
    end
  end

  def validate(value), do: invalid_flow_subject(value)

  @doc """
  Validates a canonical Flow and all Action or nested-Flow target contracts.

  This function performs no Action work. It returns the normalized Flow when
  both canonical structure and executable target contracts are valid.
  """
  @spec validate_executable(t()) :: {:ok, t()} | {:error, Exception.t()}
  def validate_executable(%__MODULE__{} = flow) do
    with {:ok, attrs} <- flow |> Map.from_struct() |> Validation.validate_executable() do
      {:ok, struct!(__MODULE__, attrs)}
    end
  end

  def validate_executable(value), do: invalid_flow_subject(value)

  @doc false
  @spec __validate_config__(map()) :: {:ok, map()} | {:error, Exception.t()}
  def __validate_config__(attrs), do: Validation.validate_config(attrs)

  defp inspection_identity(flow, nodes) do
    flow
    |> MapCodec.to_semantic_map(nodes, [])
    |> Identity.identity()
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
