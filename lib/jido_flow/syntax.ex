defmodule Jido.Flow.Syntax do
  @moduledoc """
  Shared authoring syntax for Flow surfaces.

  Macro, parser, and builder authoring paths emit this syntax layer before the
  lowerer validates and converts it into canonical `%Jido.Flow{}` artifacts.
  """

  defmodule Expr do
    @moduledoc false

    @schema Zoi.struct(
              __MODULE__,
              %{
                type: Zoi.enum([:input, :value, :result], description: "Expression type"),
                node: Zoi.atom(description: "Result node name") |> Zoi.optional(),
                path: Zoi.list(Zoi.any(), description: "Nested value path") |> Zoi.default([]),
                value: Zoi.any(description: "Literal value") |> Zoi.optional()
              },
              coerce: true
            )

    @type t :: unquote(Zoi.type_spec(@schema))

    @enforce_keys Zoi.Struct.enforce_keys(@schema)
    defstruct Zoi.Struct.struct_fields(@schema)
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
  @spec operation(atom(), map() | keyword()) :: Operation.t()
  def operation(kind, attrs \\ []) when is_atom(kind) do
    attrs = if is_list(attrs), do: Map.new(attrs), else: attrs
    %Operation{kind: kind, attrs: attrs}
  end

  @doc """
  Builds an input expression.
  """
  @spec input(term()) :: Expr.t()
  def input(path), do: %Expr{type: :input, path: normalize_path(path)}

  @doc """
  Builds a literal value expression.
  """
  @spec value(term()) :: Expr.t()
  def value(value), do: %Expr{type: :value, value: value}

  @doc """
  Builds a result reference expression.
  """
  @spec result(atom(), term()) :: Expr.t()
  def result(node, path \\ []) when is_atom(node) and not is_nil(node) do
    %Expr{type: :result, node: node, path: normalize_path(path)}
  end

  @doc """
  Appends a step operation.
  """
  @spec step(t(), atom(), module(), map()) :: t()
  def step(%__MODULE__{} = syntax, name, action, input) do
    add(
      syntax,
      operation(:step, %{
        name: name,
        action: action,
        input: input
      })
    )
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
end
