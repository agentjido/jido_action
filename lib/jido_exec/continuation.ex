defmodule Jido.Exec.Continuation do
  @moduledoc false

  alias Jido.Action.Error
  alias Jido.Executable
  alias Jido.Exec.Action.Runner
  alias Jido.Exec.Flow.Adapter, as: FlowAdapter
  alias Jido.Instruction

  @type t :: %__MODULE__{
          input: map(),
          target: Executable.target(),
          origin_action: module(),
          owner: term(),
          frame: term(),
          span: map() | nil,
          resume: (term() -> term()),
          failure: (Exception.t() -> {:ok, term()} | {:error, Exception.t()})
        }

  @enforce_keys [:input, :target, :origin_action, :owner, :resume, :failure]
  defstruct @enforce_keys ++ [frame: nil, span: nil]

  @doc false
  @spec new(map(), Executable.target(), module(), term()) :: t()
  def new(input, target, origin_action, owner)
      when is_map(input) and is_atom(origin_action) do
    %__MODULE__{
      input: input,
      target: target,
      origin_action: origin_action,
      owner: owner,
      frame: nil,
      span: nil,
      resume: & &1,
      failure: &{:error, &1}
    }
  end

  @doc false
  @spec map_result(t(), (term() -> term())) :: t()
  def map_result(%__MODULE__{} = continuation, mapper) when is_function(mapper, 1) do
    previous = continuation.resume

    resume = fn output ->
      case previous.(output) do
        %__MODULE__{} = next -> map_result(next, mapper)
        result -> mapper.(result)
      end
    end

    %{continuation | resume: resume}
  end

  @doc false
  @spec on_failure(t(), (Exception.t() -> {:ok, term()} | {:error, Exception.t()})) :: t()
  def on_failure(%__MODULE__{} = continuation, failure) when is_function(failure, 1) do
    %{continuation | failure: failure}
  end

  @doc false
  @spec with_frame(t(), term()) :: t()
  def with_frame(%__MODULE__{} = continuation, frame), do: %{continuation | frame: frame}

  @doc false
  @spec with_span(t(), map() | nil) :: t()
  def with_span(%__MODULE__{} = continuation, span), do: %{continuation | span: span}

  @doc false
  @spec resume(t(), term()) :: term()
  def resume(%__MODULE__{resume: resume}, output), do: resume.(output)

  @doc false
  @spec fail(t(), Exception.t()) :: {:ok, term()} | {:error, Exception.t()}
  def fail(%__MODULE__{failure: failure}, error), do: failure.(error)

  @doc false
  @spec run_direct(module(), map(), Executable.target(), map(), keyword(), String.t()) ::
          {:ok, term()} | {:error, Exception.t()}
  def run_direct(origin_action, input, target, context, run_opts, execution_id) do
    with :ok <- claim(run_opts, origin_action),
         {:ok, executable} <- resolve_target(target, origin_action),
         {:ok, output} <-
           execute_direct_target(executable, input, context, run_opts, execution_id) do
      validate_origin_output(origin_action, output, run_opts)
    end
  end

  @doc false
  @spec claim(keyword(), module()) :: :ok | {:error, Exception.t()}
  def claim(run_opts, origin_action) do
    counter = Keyword.fetch!(run_opts, :__jido_continuation_counter__)
    limit = Keyword.fetch!(run_opts, :max_continuations)
    count = :atomics.add_get(counter, 1, 1)

    if count <= limit do
      :ok
    else
      {:error,
       Error.execution_error("continuation limit exceeded", %{
         action: origin_action,
         count: count,
         max_continuations: limit,
         retry: false
       })}
    end
  end

  defp resolve_target(target, origin_action) do
    with {:ok, executable} <- Executable.resolve(target),
         :ok <- Executable.validate(executable) do
      {:ok, executable}
    else
      {:error, error} ->
        {:error,
         Error.execution_error("action returned an invalid continuation target", %{
           action: origin_action,
           target: target,
           cause: error,
           retry: false
         })}
    end
  end

  defp execute_direct_target(
         %Executable{kind: :action, target: action},
         input,
         context,
         run_opts,
         execution_id
       ) do
    instruction = Instruction.normalize_resolved!(action, input, context)

    case Runner.run(instruction, run_opts) do
      {:ok, output} ->
        {:ok, output}

      {:ok, output, _extra} ->
        {:ok, output}

      {:continue, next_input, next_target} ->
        run_direct(action, next_input, next_target, context, run_opts, execution_id)

      {:error, error} ->
        {:error, error}

      {:error, error, _extra} ->
        {:error, error}
    end
  end

  defp execute_direct_target(
         %Executable{kind: :flow} = executable,
         input,
         context,
         run_opts,
         execution_id
       ) do
    flow_opts = Keyword.delete(run_opts, :task_supervisor)

    case FlowAdapter.run(executable, input, context, flow_opts, execution_id) do
      {:ok, output} -> {:ok, output}
      {:error, error} -> {:error, error}
    end
  end

  defp validate_origin_output(origin_action, output, run_opts) do
    case Runner.validate_target_output(origin_action, output, run_opts) do
      {:ok, output} -> {:ok, output}
      {:error, _phase, error} -> {:error, error}
    end
  end
end
