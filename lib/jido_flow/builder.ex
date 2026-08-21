defmodule Jido.Flow.Builder do
  @moduledoc """
  Runtime builder for Flow syntax artifacts.

  The builder only constructs `Jido.Flow.Syntax`; it delegates all semantic
  validation and canonical IR construction to `Jido.Flow.Syntax.Lowerer`.
  """

  import Kernel, except: [in: 2, not: 1]

  alias Jido.Flow.Syntax
  alias Jido.Flow.Syntax.Lowerer

  @schema Zoi.struct(
            __MODULE__,
            %{
              syntax: Zoi.any(description: "Flow syntax artifact")
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc """
  Starts a builder from Flow metadata.
  """
  @spec new(map() | keyword()) :: t()
  def new(attrs), do: %__MODULE__{syntax: Syntax.new(attrs)}

  @doc false
  @spec syntax(t()) :: Syntax.t()
  def syntax(%__MODULE__{syntax: syntax}), do: syntax

  @doc """
  Lowers the builder's syntax into a canonical Flow.
  """
  @spec build(t()) :: {:ok, Jido.Flow.t()} | {:error, Exception.t()}
  def build(%__MODULE__{syntax: syntax}), do: Lowerer.lower(syntax)

  @doc false
  defdelegate input(path), to: Syntax

  @doc false
  defdelegate context(path), to: Syntax

  @doc false
  defdelegate value(value), to: Syntax

  @doc false
  defdelegate result(node, path \\ []), to: Syntax

  @doc false
  defdelegate binding(name), to: Syntax

  @doc false
  defdelegate select(source, path), to: Syntax

  @doc false
  defdelegate item(path \\ nil), to: Syntax

  @doc false
  defdelegate item_index(), to: Syntax

  @doc false
  defdelegate item_id(), to: Syntax

  @doc false
  defdelegate accumulator(path \\ nil), to: Syntax

  @doc false
  defdelegate state(path \\ nil), to: Syntax

  @doc false
  defdelegate iteration_index(), to: Syntax

  @doc false
  defdelegate body_result(path \\ nil), to: Syntax

  @doc "Builds an equality condition for a Choice option."
  defdelegate eq(left, right), to: Syntax

  @doc "Builds an inequality condition for a Choice option."
  defdelegate neq(left, right), to: Syntax

  @doc "Builds a less-than condition for a Choice option."
  defdelegate lt(left, right), to: Syntax

  @doc "Builds a less-than-or-equal condition for a Choice option."
  defdelegate lte(left, right), to: Syntax

  @doc "Builds a greater-than condition for a Choice option."
  defdelegate gt(left, right), to: Syntax

  @doc "Builds a greater-than-or-equal condition for a Choice option."
  defdelegate gte(left, right), to: Syntax

  @doc "Builds a list-membership condition for a Choice option."
  def unquote(:in)(left, right), do: apply(Syntax, :in, [left, right])

  @doc "Builds a Choice condition that requires all child conditions to be true."
  defdelegate all(conditions), to: Syntax

  @doc "Builds a Choice condition that requires one child condition to be true."
  defdelegate any(conditions), to: Syntax

  @doc "Builds a Choice condition that inverts one child condition."
  def not condition, do: apply(Syntax, :not, [condition])

  @doc "Builds one named Choice option."
  defdelegate option(name, condition, action, input \\ %{}), to: Syntax

  @doc "Builds the required Choice fallback."
  defdelegate fallback(action, input \\ %{}), to: Syntax

  @doc false
  defdelegate branch(name, operations, opts \\ []), to: Syntax

  @doc """
  Appends a provenance-only group operation.
  """
  @spec group(t(), [Syntax.Operation.t()], keyword()) :: t()
  def group(%__MODULE__{syntax: syntax} = builder, branches, opts \\ []) do
    %{builder | syntax: Syntax.group(syntax, branches, opts)}
  end

  @doc """
  Appends a step operation.
  """
  @spec step(t(), atom() | String.t() | nil, module(), term(), keyword()) :: t()
  def step(%__MODULE__{syntax: syntax} = builder, name, action, input, opts \\ []) do
    %{builder | syntax: Syntax.step(syntax, name, action, input, opts)}
  end

  @doc """
  Appends a Map fan-out operation.
  """
  @spec map(t(), atom() | String.t() | nil, term(), module(), term(), keyword()) :: t()
  def map(%__MODULE__{syntax: syntax} = builder, name, collection, action, input, opts \\ []) do
    %{builder | syntax: Syntax.map(syntax, name, collection, action, input, opts)}
  end

  @doc """
  Appends a serial Reduce fan-in operation.
  """
  @spec reduce(
          t(),
          atom() | String.t() | nil,
          term(),
          term(),
          module(),
          term(),
          keyword()
        ) :: t()
  def reduce(
        %__MODULE__{syntax: syntax} = builder,
        name,
        collection,
        initial,
        action,
        input,
        opts \\ []
      ) do
    %{
      builder
      | syntax: Syntax.reduce(syntax, name, collection, initial, action, input, opts)
    }
  end

  @doc "Appends one bounded, stateful Loop operation."
  @spec loop(t(), atom() | String.t() | nil, module(), term(), map() | keyword(), keyword()) ::
          t()
  def loop(%__MODULE__{syntax: syntax} = builder, name, action, input, state, opts \\ []) do
    %{builder | syntax: Syntax.loop(syntax, name, action, input, state, opts)}
  end

  @doc """
  Appends a named ordered Choice operation.
  """
  @spec choice(
          t(),
          atom() | String.t() | nil,
          [Syntax.Option.t()],
          Syntax.Fallback.t(),
          keyword()
        ) :: t()
  def choice(%__MODULE__{syntax: syntax} = builder, name, options, fallback, opts \\ []) do
    %{builder | syntax: Syntax.choice(syntax, name, options, fallback, opts)}
  end

  @doc """
  Appends the return declaration.
  """
  @spec return(t(), term()) :: t()
  def return(%__MODULE__{syntax: syntax} = builder, expr) do
    %{builder | syntax: Syntax.return(syntax, expr)}
  end
end
