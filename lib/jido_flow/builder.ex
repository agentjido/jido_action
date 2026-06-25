defmodule Jido.Flow.Builder do
  @moduledoc """
  Runtime builder for Flow syntax artifacts.

  The builder only constructs `Jido.Flow.Syntax`; it delegates all semantic
  validation and canonical IR construction to `Jido.Flow.Syntax.Lowerer`.
  """

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
  defdelegate shape(data), to: Syntax

  @doc false
  defdelegate branch(name, operations, opts \\ []), to: Syntax

  @doc """
  Appends a static parallel grouping operation.
  """
  @spec parallel(t(), [Syntax.Operation.t()], keyword()) :: t()
  def parallel(%__MODULE__{syntax: syntax} = builder, branches, opts \\ []) do
    %{builder | syntax: Syntax.parallel(syntax, branches, opts)}
  end

  @doc """
  Appends a step operation.
  """
  @spec step(t(), atom(), module(), term(), keyword()) :: t()
  def step(%__MODULE__{syntax: syntax} = builder, name, action, input, opts \\ []) do
    %{builder | syntax: Syntax.step(syntax, name, action, input, opts)}
  end

  @doc """
  Appends the return declaration.
  """
  @spec return(t(), term()) :: t()
  def return(%__MODULE__{syntax: syntax} = builder, expr) do
    %{builder | syntax: Syntax.return(syntax, expr)}
  end
end
