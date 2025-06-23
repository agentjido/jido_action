defmodule Jido.Flow.Step do
  @moduledoc """
  Represents a single step in a Jido.Flow pipeline.

  Steps define work to be performed on data flowing through the pipeline.
  Unlike Piper.Step, Jido.Flow.Step integrates with the Jido.Action system,
  supporting either direct function execution or Action module execution
  with full validation and error handling.

  ## Step Types

  - **Function Step**: Executes a function or MFA directly
  - **Action Step**: Executes a Jido.Action module with validation
  - **Lambda Step**: Executes an anonymous function

  ## Examples

      # Function step using MFA
      step = Jido.Flow.Step.new(
        name: "uppercase",
        work: {String, :upcase, 1}
      )

      # Action step
      step = Jido.Flow.Step.new(
        name: "process_data",
        action: MyApp.ProcessAction
      )

      # Lambda step
      step = Jido.Flow.Step.new(
        name: "transform",
        work: fn data -> String.reverse(data) end
      )
  """

  use TypedStruct
  alias Jido.Flow.Context
  alias Jido.Action.Error

  typedstruct do
    field(:name, String.t(), enforce: true)
    field(:work, function() | mfa() | nil, default: nil)
    field(:action, module() | nil, default: nil)
    field(:metadata, map(), default: %{})
  end

  @type runnable() :: {t(), Context.t()}

  @doc """
  Creates a new Step.

  ## Options

  - `:name` - Required. Name of the step
  - `:work` - Function or MFA to execute (mutually exclusive with `:action`)
  - `:action` - Jido.Action module to execute (mutually exclusive with `:work`)
  - `:metadata` - Additional metadata for the step

  ## Examples

      iex> Jido.Flow.Step.new(name: "test", work: fn x -> x * 2 end)
      %Jido.Flow.Step{name: "test", work: #Function<...>, action: nil, metadata: %{}}

      iex> Jido.Flow.Step.new(name: "action_step", action: MyAction)
      %Jido.Flow.Step{name: "action_step", work: nil, action: MyAction, metadata: %{}}
  """
  @spec new(keyword()) :: t()
  def new(params) when is_list(params) do
    name = Keyword.fetch!(params, :name)
    work = Keyword.get(params, :work)
    action = Keyword.get(params, :action)
    metadata = Keyword.get(params, :metadata, %{})

    cond do
      work && action ->
        raise ArgumentError, "Step cannot have both :work and :action"

      !work && !action ->
        raise ArgumentError, "Step must have either :work or :action"

      true ->
        %__MODULE__{
          name: name,
          work: work,
          action: action,
          metadata: metadata
        }
    end
  end

  @doc """
  Executes a step with the given context.

  Returns a new Context with the result of the step execution.
  Handles both function-based steps and Action-based steps.

  ## Examples

      iex> step = Jido.Flow.Step.new(name: "double", work: fn x -> x * 2 end)
      iex> context = Jido.Flow.Context.new(5)
      iex> {:ok, result_context} = Jido.Flow.Step.execute(step, context)
      iex> result_context.value
      10
  """
  @spec execute(t(), Context.t()) :: {:ok, Context.t()} | {:error, Error.t()}
  def execute(%__MODULE__{action: action} = step, %Context{} = context) when not is_nil(action) do
    execute_action(step, context)
  end

  def execute(%__MODULE__{work: work} = step, %Context{} = context) when not is_nil(work) do
    execute_work(step, context)
  end

  defp execute_action(%__MODULE__{action: action} = step, %Context{value: value} = context) do
    # Convert context value to params if it's a map, otherwise wrap it
    params =
      case value do
        %{} = map -> map
        other -> %{input: other}
      end

    # Use empty context for Action execution
    action_context = %{}

    # Validate params first, then run
    with {:ok, validated_params} <- action.validate_params(params),
         {:ok, result} <- action.run(validated_params, action_context),
         {:ok, validated_result} <- action.validate_output(result) do
      new_context = %Context{
        value: validated_result,
        runnable: {step, context},
        metadata: context.metadata,
        errors: context.errors
      }

      {:ok, new_context}
    else
      {:error, error} ->
        error_struct =
          case error do
            %Error{} = err -> err
            other -> Error.execution_error("Step #{step.name} failed: #{inspect(other)}")
          end

        {:error, error_struct}
    end
  end

  defp execute_work(%__MODULE__{work: work} = step, %Context{value: value} = context) do
    try do
      result =
        case work do
          {module, function, arity} when arity == 1 ->
            apply(module, function, [value])

          fun when is_function(fun, 1) ->
            fun.(value)

          _ ->
            raise ArgumentError, "Work must be a function/1 or {module, function, 1}"
        end

      new_context = %Context{
        value: result,
        runnable: {step, context},
        metadata: context.metadata,
        errors: context.errors
      }

      {:ok, new_context}
    rescue
      error ->
        error_struct = Error.execution_error("Step #{step.name} failed: #{Exception.message(error)}")
        {:error, error_struct}
    end
  end

  @doc """
  Checks if a step is an Action step.

  ## Examples

      iex> step = Jido.Flow.Step.new(name: "test", action: MyAction)
      iex> Jido.Flow.Step.action_step?(step)
      true

      iex> step = Jido.Flow.Step.new(name: "test", work: fn x -> x end)
      iex> Jido.Flow.Step.action_step?(step)
      false
  """
  @spec action_step?(t()) :: boolean()
  def action_step?(%__MODULE__{action: action}) do
    not is_nil(action)
  end

  @doc """
  Checks if a step is a work step (function/MFA).

  ## Examples

      iex> step = Jido.Flow.Step.new(name: "test", work: fn x -> x end)
      iex> Jido.Flow.Step.work_step?(step)
      true

      iex> step = Jido.Flow.Step.new(name: "test", action: MyAction)
      iex> Jido.Flow.Step.work_step?(step)
      false
  """
  @spec work_step?(t()) :: boolean()
  def work_step?(%__MODULE__{work: work}) do
    not is_nil(work)
  end

  @doc """
  Adds metadata to a step.

  ## Examples

      iex> step = Jido.Flow.Step.new(name: "test", work: fn x -> x end)
      iex> step = Jido.Flow.Step.put_meta(step, :priority, :high)
      iex> step.metadata
      %{priority: :high}
  """
  @spec put_meta(t(), atom() | String.t(), term()) :: t()
  def put_meta(%__MODULE__{metadata: metadata} = step, key, value) do
    %{step | metadata: Map.put(metadata, key, value)}
  end

  @doc """
  Gets metadata from a step.

  ## Examples

      iex> step = Jido.Flow.Step.new(name: "test", work: fn x -> x end, metadata: %{priority: :high})
      iex> Jido.Flow.Step.get_meta(step, :priority)
      :high

      iex> Jido.Flow.Step.get_meta(step, :missing, :default)
      :default
  """
  @spec get_meta(t(), atom() | String.t(), term()) :: term()
  def get_meta(%__MODULE__{metadata: metadata}, key, default \\ nil) do
    Map.get(metadata, key, default)
  end
end
