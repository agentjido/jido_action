defmodule Jido.Flow.Node do
  @moduledoc """
  A named action invocation inside a canonical Flow artifact.

  This is a read-only canonical type. Create it through the Flow module DSL,
  `Jido.Flow.Builder`, or the stored Flow decoder.
  """

  alias Jido.Action.Error
  alias Jido.Flow.Element.Validation, as: ElementValidation
  alias Jido.Flow.Expression
  alias Jido.Flow.Ref

  @config_keys [:name, :action, :input, :deps, :provenance]

  @schema Zoi.struct(
            __MODULE__,
            %{
              name: Zoi.string(description: "Flow step name"),
              action: Zoi.atom(description: "Action module"),
              input: Zoi.any(description: "Step input expression") |> Zoi.default(%{}),
              deps: Zoi.list(Zoi.string(), description: "Step dependencies") |> Zoi.default([]),
              provenance: Zoi.map(description: "Non-semantic provenance") |> Zoi.default(%{})
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc false
  @spec new(map() | keyword() | t()) :: {:ok, t()} | {:error, Exception.t()}
  def new(%__MODULE__{} = node), do: node |> Map.from_struct() |> new()

  def new(attrs) when is_list(attrs) do
    if Keyword.keyword?(attrs),
      do: attrs |> Map.new() |> new(),
      else: {:error, Error.validation_error("node configuration must be a map")}
  end

  def new(%{} = attrs) do
    with :ok <- ElementValidation.known_keys(attrs, @config_keys, "node", nil),
         {:ok, name} <- ElementValidation.name(Map.get(attrs, :name), :node),
         {:ok, action} <- ElementValidation.target(Map.get(attrs, :action), :node, nil),
         {:ok, input} <- validate_input(Map.get(attrs, :input, %{})),
         {:ok, deps} <- ElementValidation.deps(Map.get(attrs, :deps, []), :node),
         {:ok, provenance} <-
           ElementValidation.provenance(Map.get(attrs, :provenance, %{}), :node) do
      {:ok,
       %__MODULE__{
         name: name,
         action: action,
         input: input,
         deps: deps,
         provenance: provenance
       }}
    end
  end

  def new(_attrs), do: {:error, Error.validation_error("node configuration must be a map")}

  @doc false
  @spec new!(map() | keyword() | t()) :: t() | no_return()
  def new!(attrs) do
    case new(attrs) do
      {:ok, node} -> node
      {:error, error} when is_exception(error) -> raise error
    end
  end

  @doc false
  @spec to_map(t(), keyword()) :: map()
  def to_map(%__MODULE__{} = node, opts \\ []) do
    base = %{
      name: node.name,
      action: node.action,
      input: Expression.to_map(node.input),
      deps: Enum.sort(node.deps)
    }

    if Keyword.get(opts, :provenance, false) do
      Map.put(base, :provenance, node.provenance)
    else
      base
    end
  end

  @doc false
  @spec result_deps(t()) :: [String.t()]
  def result_deps(%__MODULE__{} = node) do
    node.input
    |> Expression.result_refs()
    |> Kernel.++(node.deps)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc false
  @spec normalize_expression(term()) :: {:ok, term()} | {:error, Exception.t()}
  def normalize_expression(expression), do: Expression.normalize(expression)

  @doc false
  @spec validate_expression(term(), Ref.scope()) :: :ok | {:error, Exception.t()}
  def validate_expression(expression, scope \\ :flow), do: Expression.validate(expression, scope)

  @doc false
  @spec expression_to_map(term()) :: term()
  def expression_to_map(expression), do: Expression.to_map(expression)

  @doc false
  @spec collect_result_refs(term()) :: [String.t()]
  def collect_result_refs(expression), do: Expression.result_refs(expression)

  @doc false
  @spec expression_error_kind(Exception.t()) ::
          :invalid_ref_path
          | :invalid_ref
          | :invalid_scope
          | :improper_list
          | :unsupported_expression
          | :other
  def expression_error_kind(error), do: Expression.error_kind(error)

  defp validate_input(nil), do: {:ok, %{}}

  defp validate_input(input) do
    with {:ok, input} <- Expression.normalize(input),
         :ok <- Expression.validate(input) do
      {:ok, input}
    end
  end
end
