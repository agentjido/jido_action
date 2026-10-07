defmodule Jido.Flow do
  field_docs =
    for entity <- hd(Jido.Flow.DSL.Schema.sections()).entities do
      children = for {_, children} <- entity.entities, child <- children, do: {child, "####"}

      for {entry, heading} <- [{entity, "###"} | children] do
        name = entry.name |> to_string() |> String.trim("_") |> String.capitalize()

        [
          "#{heading} #{name}\n\n#{entry.describe}\n\n",
          Spark.Options.docs(Keyword.delete(entry.schema, :__source__))
        ]
      end
    end

  @moduledoc """
  Defines the canonical Jido Flow data artifact and compile-time module DSL.

  A Flow is a declarative control program. Its leaves are Instruction
  templates, its values are computed by expressions, and Actions provide its
  executable behavior.

  A Flow contains named canonical components and one required output
  expression. Execution is delegated through `Jido.Exec`.

  Flow has three supported authoring inputs:

  * the compile-time Flow module DSL;
  * map-based data definitions through `new/1`; and
  * versioned stored JSON documents through `Jido.Flow.Codec`.

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

  A compile-time extension can add macros that expand to normal Flow
  declarations. Configure extensions as a static module list:

      use Jido.Flow,
        name: "process_order",
        extensions: [MyApp.Flows.Helpers]

  Define each extension with `Jido.Flow.Extension`. Extensions change only
  module DSL source authoring. Data definitions and Codec do not load
  extensions. The compiled result remains one canonical Flow value.

  For a small operation, bind data and write an inline Step body:

      defmodule MyApp.Greeting do
        use Jido.Flow, name: "greeting"

        flow do
          step "greet", name <- input(:name) do
            {:ok, %{message: "Hello, " <> name <> "!"}}
          end

          output result("greet")
        end
      end

  Every Flow authoring form requires an explicit, non-nil `output`. In the
  module DSL, it must be the final declaration.

  A binding source accepts direct Flow references or data, but not Flow
  operations. The body is normal Elixir in the owning module's function scope.
  Put calculations in that body. Use `ctx <- context()` to bind context as a
  parameter. Use a binding list for two or more inputs, a sole map pattern
  for complete params, or `[]` for no input. Use one binding argument. Put
  pattern selection in a `case` expression inside the body; top-level clause
  bodies are not supported.

  Use `inline:` to set the Action name, description, schemas, or
  `context: ctx`. Keep `needs:` and `meta:` at the Step level. Flow supports
  inline Actions only for Step. Map, Reduce, Choice targets, Iterate, and
  Dispatch use Action modules. All targets use normal Exec validation
  and result rules. See [Inline Actions](inline-actions.md).

  After the owner compiles, `MyApp.Greeting.step_action("greet")` returns its
  Action target for map-based definitions or trusted Registry reuse.
  It does not copy parameters, dependencies, or metadata. Map-based definitions and stored
  JSON do not accept body code, anonymous functions, or MFA targets.

  `step_action/1` stays Step-only, including explicit Action-backed Steps but
  excluding Subflows. `context: ctx` binds the current callback context; it
  does not retain the original Flow context in the target's parameters.

  Deploy the owning module and generated Action BEAM files together. A body
  edit can retain the same target and semantic graph identity; graph identity
  does not identify a deployed code version.

  Result references create data dependencies. `needs:` keeps only explicit
  author control order. Source order does not create a dependency. The Spark
  compiler keeps source locations outside the canonical Flow value.

  Use `Jido.Flow.Codec.encode/2` and `Jido.Flow.Codec.decode/2` with a trusted
  `Jido.Flow.Registry` for database or transport storage.

  A Flow module returns one stable canonical value from `flow/0` for the life
  of the loaded module version. Each validation, compilation, or execution
  operation materializes it once. Put changing runtime data in Flow input or
  context.

  Flow modules implement `Jido.Flow` and provide their definition through
  `flow/0`. The generated `run/2` delegates to `Jido.Exec` with default options.

  A Choice is one Flow component. It evaluates data-only conditions in authored
  order, runs the first matching target, and uses a required routing fallback
  when no option matches.

  Flow collects the optional effect list from every successful executed
  component and returns it with its final output. The third success element
  must be a proper list. Failed execution returns no effect list. Effect order
  uses canonical dependency order, then component name. Nested Flows occupy
  their parent position; collections use input or iteration order.

  ## DSL field reference

  These fields describe the module DSL, not map definitions or stored JSON.
  Positional arguments are identified below. Choice and Iterate require field
  blocks; their nested declarations have their own references. Only Step supports
  inline Action bodies. The field types, required flags, and defaults come from
  the Spark schemas; Jido also validates graph and cross-field rules.

  #{IO.iodata_to_binary(field_docs)}
  """

  alias Jido.Flow.Error
  alias Jido.Flow.DSL.ModuleCompiler
  alias Jido.Flow.Definition
  alias Jido.Flow.Identity

  @schema Zoi.struct(
            __MODULE__,
            %{
              name: Zoi.string(description: "Flow name"),
              description: Zoi.string(description: "Flow description") |> Zoi.optional(),
              schema: Zoi.any(description: "Flow input schema") |> Zoi.default([]),
              output_schema: Zoi.any(description: "Flow output schema") |> Zoi.default([]),
              components:
                Zoi.map(description: "Canonical named Flow component graph") |> Zoi.default(%{}),
              output: Zoi.any(description: "Declared output expression")
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))
  @type dependency_info :: %{
          needs: [String.t()],
          references: [String.t()],
          effective: [String.t()]
        }
  @type source_location :: %{optional(:file) => String.t(), optional(:line) => pos_integer()}
  @type source_map :: %{optional([term()]) => source_location()}

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the stable canonical Flow value owned by a Flow module."
  @callback flow() :: t()

  @doc "Validates Flow input parameters without running Flow work."
  @callback validate_params(term()) :: {:ok, map()} | {:error, term()}

  @doc "Validates normal Flow output or an explicit output envelope."
  @callback validate_output(map() | Jido.Action.Output.t()) ::
              {:ok, map() | Jido.Action.Output.t()} | {:error, term()}

  defmacro __using__(opts_ast) do
    quote do
      use unquote(ModuleCompiler), unquote(opts_ast)
    end
  end

  @doc false
  defmacro __before_compile__(env), do: ModuleCompiler.before_compile(env)

  @doc """
  Builds and validates one canonical Flow value from a data definition.

  Components accept tagged maps with a `kind` of `:step`, `:subflow`, `:choice`,
  `:map`, `:reduce`, `:iterate`, or `:dispatch`. Data definitions use explicit
  `:step`/`action` and `:subflow`/`flow` fields. Validation is inert.
  """
  @spec new(map()) :: {:ok, t()} | {:error, Exception.t()}
  def new(attrs) when is_map(attrs) and not is_struct(attrs) do
    with {:ok, attrs} <- Definition.validate(attrs) do
      {:ok, struct!(__MODULE__, attrs)}
    end
  end

  def new(value), do: invalid_flow_subject(value)

  @doc "Builds one canonical Flow value or raises its validation error."
  @spec new!(map()) :: t() | no_return()
  def new!(attrs) do
    case new(attrs) do
      {:ok, flow} -> flow
      {:error, error} when is_exception(error) -> raise error
    end
  end

  @doc """
  Converts a Flow artifact to its deterministic semantic map.

  Components use deterministic dependency order, then component name. Use
  `Jido.Flow.Codec` for database storage.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = flow) do
    %{
      name: flow.name,
      description: flow.description,
      schema: flow.schema,
      output_schema: flow.output_schema,
      components: Definition.to_map(flow.components),
      output: Jido.Flow.Value.to_map(flow.output)
    }
  end

  defp invalid_flow_subject(value) do
    Definition.invalid_subject(value)
  end

  @doc """
  Returns explicit, reference, and effective dependencies for each component.
  """
  @spec dependencies(t()) ::
          {:ok, %{String.t() => dependency_info()}}
          | {:error, Error.InvalidDefinitionError.t()}
  def dependencies(%__MODULE__{} = flow) do
    with {:ok, flow} <- validate(flow) do
      {:ok, dependency_map(flow)}
    end
  end

  def dependencies(value), do: invalid_flow_subject(value)

  @doc """
  Returns the versioned canonical inspection data for a Flow.
  """
  @spec explain(t()) :: {:ok, map()} | {:error, Error.InvalidDefinitionError.t()}
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
         components: Definition.to_map(flow.components),
         dependencies: dependency_map(flow),
         output: Jido.Flow.Value.to_map(flow.output),
         identity: Identity.for_flow(flow)
       }}
    end
  end

  def explain(value), do: invalid_flow_subject(value)

  @doc """
  Returns the deterministic SHA-256 and UUIDv8 identity for a Flow.
  """
  @spec semantic_identity(t()) ::
          {:ok, map()} | {:error, Error.InvalidDefinitionError.t()}
  def semantic_identity(%__MODULE__{} = flow) do
    with {:ok, flow} <- validate(flow) do
      {:ok, Identity.for_flow(flow)}
    end
  end

  def semantic_identity(value), do: invalid_flow_subject(value)

  @doc """
  Validates the exact canonical Flow structure.

  This function checks schemas, components, expressions, references,
  dependencies, and graph cycles. It is inert: it does not load or check
  Action targets. `Jido.Exec.compile/2` checks executable target contracts.
  """
  @spec validate(t()) :: {:ok, t()} | {:error, Exception.t()}
  def validate(%__MODULE__{} = flow) do
    with {:ok, attrs} <-
           Definition.validate_canonical(%{
             name: flow.name,
             description: flow.description,
             schema: flow.schema,
             output_schema: flow.output_schema,
             components: flow.components,
             output: flow.output
           }) do
      {:ok, struct!(__MODULE__, attrs)}
    end
  end

  def validate(value), do: invalid_flow_subject(value)

  @doc false
  @spec __validate_config__(map()) :: {:ok, map()} | {:error, Exception.t()}
  def __validate_config__(attrs), do: Definition.validate_config(attrs)

  defp dependency_map(flow) do
    Map.new(flow.components, fn {name, node} ->
      needs = Definition.needs(node)
      references = Definition.reference_dependencies(node)

      {name,
       %{
         needs: needs,
         references: references,
         effective: Enum.sort(Enum.uniq(needs ++ references))
       }}
    end)
  end
end
