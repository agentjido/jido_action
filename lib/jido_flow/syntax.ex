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
                type:
                  Zoi.enum([:input, :value, :result, :binding, :select, :shape],
                    description: "Expression type"
                  ),
                node: Zoi.atom(description: "Result node name") |> Zoi.optional(),
                binding: Zoi.atom(description: "Source binding alias") |> Zoi.optional(),
                source: Zoi.any(description: "Projection source expression") |> Zoi.optional(),
                path: Zoi.list(Zoi.any(), description: "Nested value path") |> Zoi.default([]),
                value: Zoi.any(description: "Literal value") |> Zoi.optional(),
                data: Zoi.any(description: "Structured shape data") |> Zoi.optional()
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
  Builds a readability-only structured data expression.
  """
  @spec shape(term()) :: Expr.t()
  def shape(data), do: %Expr{type: :shape, data: data}

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
  Appends a static parallel grouping operation.
  """
  @spec parallel(t(), [Operation.t()], keyword()) :: t()
  def parallel(%__MODULE__{} = syntax, branches, opts \\ []) do
    add(
      syntax,
      operation(:parallel, %{branches: branches}, provenance: Keyword.get(opts, :provenance, %{}))
    )
  end

  @doc """
  Appends a step operation.
  """
  @spec step(t(), atom(), module(), term(), keyword()) :: t()
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
      operation(:step, attrs, provenance: Keyword.get(opts, :provenance, %{}))
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

  defp maybe_put_binding(attrs, nil), do: attrs
  defp maybe_put_binding(attrs, binding), do: Map.put(attrs, :binding, binding)

  defp maybe_put_after(attrs, nil), do: attrs
  defp maybe_put_after(attrs, after_targets), do: Map.put(attrs, :after, after_targets)
end
