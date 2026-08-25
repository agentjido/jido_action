defmodule Jido.Flow do
  @moduledoc """
  Defines the canonical Jido Flow data artifact and compile-time module DSL.

  A Flow contains named canonical components and one required output
  expression. Execution is delegated through `Jido.Exec`.

  Flow has four supported authoring inputs:

  * the compile-time Flow module DSL;
  * `Jido.Flow.Builder` for runtime construction; and
  * versioned stored JSON documents through `Jido.Flow.Codec`; and
  * direct canonical struct construction.

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

          output result("save")
        end
      end

  Result references create data dependencies. `after:` keeps only explicit
  author control order. Source order does not create a dependency. The Spark
  compiler keeps source locations outside the canonical Flow value.

  Use `Jido.Flow.Codec.encode/2` and `Jido.Flow.Codec.decode/2` with a trusted
  `Jido.Flow.Registry` for database or transport storage.

  A Choice is one Flow component. It evaluates data-only conditions in authored
  order, runs the first matching target, and uses a required routing fallback
  when no option matches.

  Flow components consume only an Action output or error reason. Extra values from
  an Action callback are returned only to direct Action or Instruction callers.
  Flow execution discards them.
  """

  alias Jido.Action.Error
  alias Jido.Flow.DSL.ModuleCompiler
  alias Jido.Flow.Compiler
  alias Jido.Flow.Compiled
  alias Jido.Flow.Component
  alias Jido.Flow.Graph
  alias Jido.Flow.Identity
  alias Jido.Flow.Validation

  @schema Zoi.struct(
            __MODULE__,
            %{
              name: Zoi.string(description: "Flow name"),
              description: Zoi.string(description: "Flow description") |> Zoi.optional(),
              schema: Zoi.any(description: "Flow input schema") |> Zoi.default([]),
              output_schema: Zoi.any(description: "Flow output schema") |> Zoi.default([]),
              components:
                Zoi.list(Zoi.any(), description: "Canonical Flow components") |> Zoi.default([]),
              output: Zoi.any(description: "Declared output expression")
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))
  @type dependency_info :: %{
          after: [String.t()],
          references: [String.t()],
          effective: [String.t()]
        }

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  defmacro __using__(opts_ast), do: ModuleCompiler.using(opts_ast)

  @doc false
  defmacro __before_compile__(env), do: ModuleCompiler.before_compile(env)

  @doc false
  @spec new(map() | keyword() | t()) :: {:ok, t()} | {:error, Exception.t()}
  def new(%__MODULE__{} = flow), do: flow |> Map.from_struct() |> new()

  def new(attrs) do
    with {:ok, attrs} <- Validation.new(attrs) do
      {:ok, struct!(__MODULE__, attrs)}
    end
  end

  @doc false
  @spec new!(map() | keyword() | t()) :: t() | no_return()
  def new!(attrs) do
    case new(attrs) do
      {:ok, flow} -> flow
      {:error, error} when is_exception(error) -> raise error
    end
  end

  @doc """
  Compiles a validated Flow to one native Runic workflow.

  The returned value contains derived runtime data. It is not an authoring or
  storage format. Use `Jido.Flow.Codec` to store a Flow.
  """
  @spec compile(t(), keyword() | Compiled.source_map()) ::
          {:ok, Compiled.t()} | {:error, Exception.t()}
  def compile(flow, opts \\ [])
  def compile(%__MODULE__{} = flow, opts), do: Compiler.compile(flow, opts)

  def compile(value, _opts), do: invalid_flow_subject(value)

  @doc "Compiles a Flow or raises the compilation error."
  @spec compile!(t(), keyword() | Compiled.source_map()) :: Compiled.t() | no_return()
  def compile!(%__MODULE__{} = flow, opts \\ []) do
    case compile(flow, opts) do
      {:ok, compiled} -> compiled
      {:error, error} -> raise error
    end
  end

  @doc """
  Converts a Flow artifact to its deterministic semantic map.

  Component order in this view is author declaration order. Use
  `Jido.Flow.Codec` for database storage.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = flow) do
    %{
      name: flow.name,
      description: flow.description,
      schema: flow.schema,
      output_schema: flow.output_schema,
      components: Enum.map(flow.components, &Component.to_map/1),
      output: Jido.Flow.Expression.to_map(flow.output)
    }
  end

  @doc false
  @spec canonical_components([Component.t()]) :: [Component.t()]
  def canonical_components(components), do: Graph.canonical_components(components)

  defp invalid_flow_subject(value) do
    Validation.invalid_subject(value)
  end

  @doc """
  Returns explicit, reference, and effective dependencies for each component.
  """
  @spec dependencies(t()) ::
          {:ok, %{String.t() => dependency_info()}} | {:error, Error.InvalidInputError.t()}
  def dependencies(%__MODULE__{} = flow) do
    with {:ok, flow} <- validate(flow) do
      {:ok, dependency_map(flow)}
    end
  end

  def dependencies(value), do: invalid_flow_subject(value)

  @doc """
  Returns the versioned canonical inspection data for a Flow.
  """
  @spec explain(t()) :: {:ok, map()} | {:error, Error.InvalidInputError.t()}
  def explain(%__MODULE__{} = flow) do
    with {:ok, flow} <- validate(flow) do
      {:ok,
       %{
         version: 1,
         kind: :flow,
         name: flow.name,
         description: flow.description,
         schema: flow.schema,
         output_schema: flow.output_schema,
         components: Graph.canonical_components(flow.components),
         dependencies: dependency_map(flow),
         output: Jido.Flow.Expression.to_map(flow.output),
         identity: Identity.for_flow(flow)
       }}
    end
  end

  def explain(value), do: invalid_flow_subject(value)

  @doc """
  Returns the deterministic SHA-256 and UUIDv8 identity for a Flow.
  """
  @spec semantic_identity(t()) :: {:ok, map()} | {:error, Error.InvalidInputError.t()}
  def semantic_identity(%__MODULE__{} = flow) do
    with {:ok, flow} <- validate(flow) do
      {:ok, Identity.for_flow(flow)}
    end
  end

  def semantic_identity(value), do: invalid_flow_subject(value)

  @doc """
  Validates and normalizes the canonical Flow structure.

  This function checks schemas, components, expressions, references, dependencies,
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

  defp dependency_map(flow) do
    Map.new(flow.components, fn component ->
      after_names = Component.after_of(component)
      references = Component.reference_dependencies(component)

      {Component.name_of(component),
       %{
         after: after_names,
         references: references,
         effective: Enum.sort(Enum.uniq(after_names ++ references))
       }}
    end)
  end
end
