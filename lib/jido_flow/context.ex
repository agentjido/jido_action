defmodule Jido.Flow.Context do
  @moduledoc """
  Represents data flowing through a Jido.Flow pipeline.

  Context encapsulates both the data value and execution metadata,
  similar to Piper.Fact but aligned with Jido's context patterns.
  Unlike Piper.Fact, Context integrates with Jido.Action's validation
  and error handling systems.
  """

  use TypedStruct

  typedstruct do
    field(:value, term(), enforce: true)
    field(:runnable, {Jido.Flow.Step.t(), __MODULE__.t()} | nil, default: nil)
    field(:metadata, map(), default: %{})
    field(:errors, [Jido.Action.Error.t()], default: [])
  end

  @doc """
  Creates a new Context with the given value.

  ## Examples

      iex> Jido.Flow.Context.new("hello")
      %Jido.Flow.Context{value: "hello", runnable: nil, metadata: %{}, errors: []}

      iex> Jido.Flow.Context.new(%{data: "test"}, %{source: "input"})
      %Jido.Flow.Context{
        value: %{data: "test"},
        runnable: nil,
        metadata: %{source: "input"},
        errors: []
      }
  """
  @spec new(term(), map()) :: t()
  def new(value, metadata \\ %{}) do
    %__MODULE__{
      value: value,
      metadata: metadata
    }
  end

  @doc """
  Adds metadata to the context.

  ## Examples

      iex> context = Jido.Flow.Context.new("hello")
      iex> Jido.Flow.Context.put_meta(context, :step_count, 1)
      %Jido.Flow.Context{
        value: "hello",
        runnable: nil,
        metadata: %{step_count: 1},
        errors: []
      }
  """
  @spec put_meta(t(), atom() | String.t(), term()) :: t()
  def put_meta(%__MODULE__{metadata: metadata} = context, key, value) do
    %{context | metadata: Map.put(metadata, key, value)}
  end

  @doc """
  Gets metadata from the context.

  ## Examples

      iex> context = Jido.Flow.Context.new("hello", %{step_count: 1})
      iex> Jido.Flow.Context.get_meta(context, :step_count)
      1

      iex> Jido.Flow.Context.get_meta(context, :missing, "default")
      "default"
  """
  @spec get_meta(t(), atom() | String.t(), term()) :: term()
  def get_meta(%__MODULE__{metadata: metadata}, key, default \\ nil) do
    Map.get(metadata, key, default)
  end

  @doc """
  Adds an error to the context.

  ## Examples

      iex> context = Jido.Flow.Context.new("hello")
      iex> error = Jido.Action.Error.validation_error("Invalid input")
      iex> Jido.Flow.Context.add_error(context, error)
      %Jido.Flow.Context{
        value: "hello",
        runnable: nil,
        metadata: %{},
        errors: [%Jido.Action.Error{type: :validation_error, message: "Invalid input"}]
      }
  """
  @spec add_error(t(), Jido.Action.Error.t()) :: t()
  def add_error(%__MODULE__{errors: errors} = context, %Jido.Action.Error{} = error) do
    %{context | errors: [error | errors]}
  end

  @doc """
  Checks if the context has any errors.

  ## Examples

      iex> context = Jido.Flow.Context.new("hello")
      iex> Jido.Flow.Context.has_errors?(context)
      false

      iex> error = Jido.Action.Error.validation_error("Invalid input")
      iex> context_with_error = Jido.Flow.Context.add_error(context, error)
      iex> Jido.Flow.Context.has_errors?(context_with_error)
      true
  """
  @spec has_errors?(t()) :: boolean()
  def has_errors?(%__MODULE__{errors: errors}) do
    length(errors) > 0
  end

  @doc """
  Removes the runnable from the context, creating a clean context for the next step.

  This is used when passing data between pipeline steps to avoid carrying
  forward execution metadata that's no longer relevant.

  ## Examples

      iex> step = %Jido.Flow.Step{name: "test_step", action: TestAction}
      iex> context = %Jido.Flow.Context{value: "hello", runnable: {step, %Jido.Flow.Context{}}}
      iex> Jido.Flow.Context.clean(context)
      %Jido.Flow.Context{value: "hello", runnable: nil, metadata: %{}, errors: []}
  """
  @spec clean(t()) :: t()
  def clean(%__MODULE__{} = context) do
    %{context | runnable: nil}
  end
end
