defmodule Jido.Flow.Syntax do
  @moduledoc """
  Shared authoring syntax for Flow surfaces.

  Macro, parser, and builder authoring paths emit this syntax layer before the
  lowerer validates and converts it into canonical `%Jido.Flow{}` artifacts.
  """

  import Kernel, except: [in: 2, not: 1]

  defmodule Expr do
    @moduledoc false

    @schema Zoi.struct(
              __MODULE__,
              %{
                type:
                  Zoi.enum([:input, :context, :value, :result, :binding, :select],
                    description: "Expression type"
                  ),
                node: Zoi.string(description: "Result node name") |> Zoi.optional(),
                binding: Zoi.atom(description: "Source binding alias") |> Zoi.optional(),
                source: Zoi.any(description: "Projection source expression") |> Zoi.optional(),
                path: Zoi.list(Zoi.any(), description: "Nested value path") |> Zoi.default([]),
                value: Zoi.any(description: "Literal value") |> Zoi.optional()
              },
              coerce: true
            )

    @type t :: unquote(Zoi.type_spec(@schema))

    @enforce_keys Zoi.Struct.enforce_keys(@schema)
    defstruct Zoi.Struct.struct_fields(@schema)
  end

  defmodule Condition do
    @moduledoc false

    @enforce_keys [:operator, :operands]
    defstruct [:operator, :operands]
  end

  defmodule Option do
    @moduledoc false

    @enforce_keys [:name, :condition, :action, :input]
    defstruct [:name, :condition, :action, :input]
  end

  defmodule Fallback do
    @moduledoc false

    @enforce_keys [:action, :input]
    defstruct [:action, :input]
  end

  defmodule Operation do
    @moduledoc false

    @schema Zoi.struct(
              __MODULE__,
              %{
                kind: Zoi.atom(description: "Syntax operation kind"),
                attrs: Zoi.map(description: "Operation attributes") |> Zoi.default(%{}),
                provenance: Zoi.map(description: "Non-semantic provenance") |> Zoi.default(%{})
              },
              coerce: true
            )

    @type t :: unquote(Zoi.type_spec(@schema))

    @enforce_keys Zoi.Struct.enforce_keys(@schema)
    defstruct Zoi.Struct.struct_fields(@schema)
  end

  @schema Zoi.struct(
            __MODULE__,
            %{
              name: Zoi.string(description: "Flow name"),
              description: Zoi.string(description: "Flow description") |> Zoi.optional(),
              schema: Zoi.any(description: "Flow input schema") |> Zoi.default([]),
              output_schema: Zoi.any(description: "Flow output schema") |> Zoi.default([]),
              operations:
                Zoi.list(Zoi.any(), description: "Flow syntax operations") |> Zoi.default([]),
              provenance: Zoi.map(description: "Non-semantic provenance") |> Zoi.default(%{})
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc """
  Builds an empty syntax artifact.
  """
  @spec new(map() | keyword()) :: t()
  def new(attrs) when is_list(attrs), do: attrs |> Map.new() |> new()
  def new(%{} = attrs), do: struct!(__MODULE__, attrs)

  @doc """
  Appends a syntax operation.
  """
  @spec add(t(), Operation.t()) :: t()
  def add(%__MODULE__{} = syntax, %Operation{} = operation) do
    %{syntax | operations: syntax.operations ++ [operation]}
  end

  @doc """
  Builds a generic syntax operation.
  """
  @spec operation(atom(), map() | keyword(), keyword()) :: Operation.t()
  def operation(kind, attrs \\ [], opts \\ []) when is_atom(kind) do
    attrs = if is_list(attrs), do: Map.new(attrs), else: attrs
    %Operation{kind: kind, attrs: attrs, provenance: Keyword.get(opts, :provenance, %{})}
  end

  @doc """
  Builds an input expression.
  """
  @spec input(term()) :: Expr.t()
  def input(path), do: %Expr{type: :input, path: normalize_path(path)}

  @doc """
  Builds a runtime context expression.
  """
  @spec context(term()) :: Expr.t()
  def context(path), do: %Expr{type: :context, path: normalize_path(path)}

  @doc """
  Builds a literal value expression.
  """
  @spec value(term()) :: Expr.t()
  def value(value), do: %Expr{type: :value, value: value}

  @doc """
  Builds a result reference expression.
  """
  @spec result(atom() | String.t(), term()) :: Expr.t()
  def result(node, path \\ []) do
    %Expr{type: :result, node: normalize_node_name(node), path: normalize_path(path)}
  end

  @doc """
  Builds a source-level binding expression.
  """
  @spec binding(atom()) :: Expr.t()
  def binding(name), do: %Expr{type: :binding, binding: name}

  @doc """
  Builds a projection expression over an existing Flow source.
  """
  @spec select(term(), term()) :: Expr.t()
  def select(source, path), do: %Expr{type: :select, source: source, path: normalize_path(path)}

  @doc """
  Builds an equality condition for a Choice option.
  """
  @spec eq(term(), term()) :: Condition.t()
  def eq(left, right), do: condition(:eq, [left, right])

  @doc "Builds an inequality condition for a Choice option."
  @spec neq(term(), term()) :: Condition.t()
  def neq(left, right), do: condition(:neq, [left, right])

  @doc "Builds a less-than condition for a Choice option."
  @spec lt(term(), term()) :: Condition.t()
  def lt(left, right), do: condition(:lt, [left, right])

  @doc "Builds a less-than-or-equal condition for a Choice option."
  @spec lte(term(), term()) :: Condition.t()
  def lte(left, right), do: condition(:lte, [left, right])

  @doc "Builds a greater-than condition for a Choice option."
  @spec gt(term(), term()) :: Condition.t()
  def gt(left, right), do: condition(:gt, [left, right])

  @doc "Builds a greater-than-or-equal condition for a Choice option."
  @spec gte(term(), term()) :: Condition.t()
  def gte(left, right), do: condition(:gte, [left, right])

  @doc "Builds a list-membership condition for a Choice option."
  @spec unquote(:in)(term(), term()) :: Condition.t()
  def unquote(:in)(left, right), do: condition(:in, [left, right])

  @doc "Builds a Choice condition that requires all child conditions to be true."
  @spec all([Condition.t()]) :: Condition.t()
  def all(conditions), do: condition(:all, conditions)

  @doc "Builds a Choice condition that requires one child condition to be true."
  @spec any([Condition.t()]) :: Condition.t()
  def any(conditions), do: condition(:any, conditions)

  @doc "Builds a Choice condition that inverts one child condition."
  @spec not Condition.t() :: Condition.t()
  def not condition, do: condition(:not, [condition])

  @doc """
  Builds one named Choice option.
  """
  @spec option(atom() | String.t(), Condition.t(), module(), term()) :: Option.t()
  def option(name, condition, action, input \\ %{}) do
    %Option{name: name, condition: condition, action: action, input: input}
  end

  @doc """
  Builds the required Choice fallback.
  """
  @spec fallback(module(), term()) :: Fallback.t()
  def fallback(action, input \\ %{}), do: %Fallback{action: action, input: input}

  @doc """
  Builds a named branch operation for static branch grouping.
  """
  @spec branch(atom(), [Operation.t()], keyword()) :: Operation.t()
  def branch(name, operations, opts \\ []) do
    operation(
      :branch,
      %{name: name, operations: operations},
      provenance: Keyword.get(opts, :provenance, %{})
    )
  end

  @doc """
  Appends a provenance-only group operation.
  """
  @spec group(t(), [Operation.t()], keyword()) :: t()
  def group(%__MODULE__{} = syntax, branches, opts \\ []) do
    add(
      syntax,
      operation(:group, %{branches: branches}, provenance: Keyword.get(opts, :provenance, %{}))
    )
  end

  @doc """
  Appends a step operation.
  """
  @spec step(t(), atom() | String.t() | nil, module(), term(), keyword()) :: t()
  def step(%__MODULE__{} = syntax, name, action, input, opts \\ []) do
    attrs =
      %{
        name: name,
        action: action,
        input: input
      }
      |> maybe_put_binding(Keyword.get(opts, :bind))
      |> maybe_put_after(Keyword.get(opts, :after))

    add(
      syntax,
      operation(:step, attrs, provenance: provenance_from_options(opts))
    )
  end

  @doc """
  Appends a named ordered Choice operation.
  """
  @spec choice(t(), atom() | String.t() | nil, [Option.t()], Fallback.t(), keyword()) :: t()
  def choice(%__MODULE__{} = syntax, name, options, fallback, opts \\ []) do
    attrs =
      %{
        name: name,
        options: options,
        fallback: fallback
      }
      |> maybe_put_binding(Keyword.get(opts, :bind))
      |> maybe_put_after(Keyword.get(opts, :after))

    add(syntax, operation(:choice, attrs, provenance: provenance_from_options(opts)))
  end

  @doc """
  Appends the return declaration.
  """
  @spec return(t(), term()) :: t()
  def return(%__MODULE__{} = syntax, expr) do
    add(syntax, operation(:return, %{expr: expr}))
  end

  defp normalize_path(nil), do: []
  defp normalize_path(path) when is_list(path), do: path
  defp normalize_path(path), do: [path]

  defp normalize_node_name(node) when is_atom(node) and node != nil, do: Atom.to_string(node)
  defp normalize_node_name(node) when is_binary(node), do: node

  defp condition(operator, operands), do: %Condition{operator: operator, operands: operands}

  defp maybe_put_binding(attrs, nil), do: attrs
  defp maybe_put_binding(attrs, binding), do: Map.put(attrs, :binding, binding)

  defp maybe_put_after(attrs, nil), do: attrs
  defp maybe_put_after(attrs, after_targets), do: Map.put(attrs, :after, after_targets)

  defp provenance_from_options(opts) do
    provenance = Keyword.get(opts, :provenance, %{})

    if is_map(provenance) do
      Map.merge(provenance, annotation_options(opts))
    else
      provenance
    end
  end

  defp annotation_options(opts) do
    opts
    |> Keyword.take([:label, :tags, :note])
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end
end
