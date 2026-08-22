defmodule Jido.Flow.Builder do
  @moduledoc """
  Builds Flow artifacts from runtime data.

  The builder uses the same semantic validation as the compile-time DSL. It is
  a runtime data-construction API, not a second source language. Developers
  normally use the compile-time DSL from `Jido.Flow`.
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

  @typedoc "A closed data expression used by the runtime Builder."
  @opaque expression :: Syntax.Expr.t()

  @typedoc "A closed Choice or Iterator condition."
  @opaque condition :: Syntax.Condition.t()

  @typedoc "One named Choice option."
  @opaque choice_option :: Syntax.Option.t()

  @typedoc "The required Choice fallback."
  @opaque choice_fallback :: Syntax.Fallback.t()

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

  @doc "Builds a reference to Flow input at `path`."
  @spec input(term()) :: expression()
  defdelegate input(path), to: Syntax

  @doc "Builds a reference to runtime context at `path`."
  @spec context(term()) :: expression()
  defdelegate context(path), to: Syntax

  @doc "Wraps one literal value for use in a runtime expression."
  @spec value(term()) :: expression()
  defdelegate value(value), to: Syntax

  @doc "Builds a reference to a named node result, with an optional `path`."
  @spec result(atom() | String.t(), term()) :: expression()
  defdelegate result(node, path \\ []), to: Syntax

  @doc false
  @spec binding(atom()) :: expression()
  defdelegate binding(name), to: Syntax

  @doc "Projects `path` from another reference expression."
  @spec select(expression(), term()) :: expression()
  defdelegate select(source, path), to: Syntax

  @doc "Builds a scoped reference to the current Map or Reduce item."
  @spec item(term()) :: expression()
  defdelegate item(path \\ nil), to: Syntax

  @doc "Builds a scoped reference to the zero-based collection item index."
  @spec item_index() :: expression()
  defdelegate item_index(), to: Syntax

  @doc "Builds a scoped reference to the stable collection item identifier."
  @spec item_id() :: expression()
  defdelegate item_id(), to: Syntax

  @doc "Builds a scoped reference to the current Reduce accumulator."
  @spec accumulator(term()) :: expression()
  defdelegate accumulator(path \\ nil), to: Syntax

  @doc "Builds a scoped reference to the current Iterator State."
  @spec state(term()) :: expression()
  defdelegate state(path \\ nil), to: Syntax

  @doc "Builds a scoped reference to the zero-based Iterator index."
  @spec iteration_index() :: expression()
  defdelegate iteration_index(), to: Syntax

  @doc "Builds a scoped reference to the latest Iterator body result."
  @spec body_result(term()) :: expression()
  defdelegate body_result(path \\ nil), to: Syntax

  @doc "Builds an equality condition for a Choice option."
  @spec eq(term(), term()) :: condition()
  defdelegate eq(left, right), to: Syntax

  @doc "Builds an inequality condition for a Choice option."
  @spec neq(term(), term()) :: condition()
  defdelegate neq(left, right), to: Syntax

  @doc "Builds a less-than condition for a Choice option."
  @spec lt(term(), term()) :: condition()
  defdelegate lt(left, right), to: Syntax

  @doc "Builds a less-than-or-equal condition for a Choice option."
  @spec lte(term(), term()) :: condition()
  defdelegate lte(left, right), to: Syntax

  @doc "Builds a greater-than condition for a Choice option."
  @spec gt(term(), term()) :: condition()
  defdelegate gt(left, right), to: Syntax

  @doc "Builds a greater-than-or-equal condition for a Choice option."
  @spec gte(term(), term()) :: condition()
  defdelegate gte(left, right), to: Syntax

  @doc "Builds a list-membership condition for a Choice option."
  @spec unquote(:in)(term(), term()) :: condition()
  def unquote(:in)(left, right), do: apply(Syntax, :in, [left, right])

  @doc "Builds a Choice condition that requires all child conditions to be true."
  @spec all([condition()]) :: condition()
  defdelegate all(conditions), to: Syntax

  @doc "Builds a Choice condition that requires one child condition to be true."
  @spec any([condition()]) :: condition()
  defdelegate any(conditions), to: Syntax

  @doc "Builds a Choice condition that inverts one child condition."
  @spec unquote(:not)(condition()) :: condition()
  def not condition, do: apply(Syntax, :not, [condition])

  @doc "Builds one named Choice option."
  @spec option(atom() | String.t(), condition(), module(), term()) :: choice_option()
  defdelegate option(name, condition, action, input \\ %{}), to: Syntax

  @doc "Builds the required Choice fallback."
  @spec fallback(module(), term()) :: choice_fallback()
  defdelegate fallback(action, input \\ %{}), to: Syntax

  @doc false
  defdelegate branch(name, operations, opts \\ []), to: Syntax

  @doc false
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

  @doc "Appends one bounded, stateful Iterate operation."
  @spec iterate(t(), atom() | String.t() | nil, module(), term(), map() | keyword(), keyword()) ::
          t()
  def iterate(%__MODULE__{syntax: syntax} = builder, name, action, input, state, opts \\ []) do
    %{builder | syntax: Syntax.iterate(syntax, name, action, input, state, opts)}
  end

  @doc """
  Appends a named ordered Choice operation.
  """
  @spec choice(
          t(),
          atom() | String.t() | nil,
          [choice_option()],
          choice_fallback(),
          keyword()
        ) :: t()
  def choice(%__MODULE__{syntax: syntax} = builder, name, options, fallback, opts \\ []) do
    %{builder | syntax: Syntax.choice(syntax, name, options, fallback, opts)}
  end

  @doc """
  Appends the Flow output expression.

  This runtime function is named `return/2` because it writes the canonical
  Flow `:return` field. The compile-time DSL uses `output` for the same concept.
  """
  @spec return(t(), term()) :: t()
  def return(%__MODULE__{syntax: syntax} = builder, expr) do
    %{builder | syntax: Syntax.return(syntax, expr)}
  end
end
