defmodule Jido.Flow do
  @moduledoc """
  Defines the canonical Jido Flow artifact and compile-time module DSL.

  A Flow is a data artifact describing named Action calls, ordered Choices,
  Map fan-out, Reduce fan-in, bounded Iterate nodes, and one output expression.
  Execution is delegated through `Jido.Exec`.

  Flow has three supported inputs:

  * the compile-time Flow module DSL;
  * `Jido.Flow.Builder` for runtime construction; and
  * versioned stored maps or JSON for transport and storage.

  Use the Flow module DSL as the primary developer authoring surface:

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

  All three inputs use the same constructor and produce the same canonical
  Flow. Flow element structs and semantic maps are views of this model. They
  are not additional source languages. Do not use direct struct construction
  as an authoring API.

  The module DSL names the final declaration `output`. The canonical artifact
  and Builder name its field `return`. The module DSL also names a repeated
  form `iterate`; the canonical node type is `Jido.Flow.Iterator`. These names
  mark source and data boundaries. They do not define aliases or extra forms.

  Use `to_stored_map/3` and `from_stored_map/2` with a trusted
  `Jido.Flow.Registry` for versioned storage. There is no runtime parser for
  DSL source.

  The Flow compiler, Map codec internals, graph analysis, and graph engine
  adapters are private. Use this module and `Jido.Exec` as the public facade.

  A Choice is one Flow node. It evaluates data-only conditions in authored
  order, runs the first matching target, and uses a required routing fallback
  when no option matches.

  Flow nodes consume only an Action output or error reason. Extra values from
  an Action callback are returned only to direct Action or Instruction callers.
  Flow execution discards them.
  """

  alias Jido.Action.Error
  alias Jido.Flow.DSL.ModuleCompiler
  alias Jido.Flow.Element
  alias Jido.Flow.Graph
  alias Jido.Flow.Inspection
  alias Jido.Flow.MapCodec
  alias Jido.Flow.SemanticMap
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

  defmacro __using__(opts_ast), do: ModuleCompiler.using(opts_ast)

  @doc false
  defmacro __before_compile__(env), do: ModuleCompiler.before_compile(env)

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
    SemanticMap.build(flow, opts)
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
  the same canonical constructor as the Flow module DSL and Builder. It does
  not create atoms or derive module names from stored data.
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
      Inspection.dependencies(flow)
    end
  end

  def dependencies(value), do: invalid_flow_subject(value)

  @doc """
  Returns the versioned canonical inspection data for a Flow.
  """
  @spec explain(t()) :: {:ok, map()} | {:error, Error.InvalidInputError.t()}
  def explain(%__MODULE__{} = flow) do
    with {:ok, flow} <- validate(flow) do
      Inspection.explain(flow)
    end
  end

  def explain(value), do: invalid_flow_subject(value)

  @doc """
  Returns the deterministic SHA-256 and UUIDv8 identity for a Flow.
  """
  @spec semantic_identity(t()) :: {:ok, map()} | {:error, Error.InvalidInputError.t()}
  def semantic_identity(%__MODULE__{} = flow) do
    with {:ok, flow} <- validate(flow) do
      Inspection.semantic_identity(flow)
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
end
