defmodule Jido.Tools.Workflow.Execution do
  @moduledoc false

  alias Jido.Action.Error
  alias Jido.Exec
  alias Jido.Exec.Supervisors
  alias Jido.Instruction

  @spec execute_workflow(list(), map(), map(), module()) :: {:ok, map()} | {:error, any()}
  def execute_workflow(steps, params, context, module) do
    initial_acc = {:ok, params, %{}}

    steps
    |> Enum.reduce_while(initial_acc, &reduce_step(&1, &2, context, module))
    |> case do
      {:ok, _final_params, final_results} -> {:ok, final_results}
      {:error, reason} -> {:error, reason}
    end
  end

  defp reduce_step(step, {_status, current_params, results}, context, module) do
    case module.execute_step(step, current_params, context) do
      {:ok, step_result} when is_map(step_result) ->
        updated_results = Map.merge(results, step_result)
        updated_params = Map.merge(current_params, step_result)
        {:cont, {:ok, updated_params, updated_results}}

      {:ok, step_result} ->
        {:halt,
         {:error,
          %{type: :invalid_step_result, message: "Expected map, got: #{inspect(step_result)}"}}}

      {:error, reason} ->
        {:halt, {:error, reason}}
    end
  end

  @doc false
  @spec execute_step(tuple(), map(), map(), module()) :: {:ok, any()} | {:error, any()}
  def execute_step(step, params, context, module) do
    case step do
      {:step, _metadata, [instruction]} ->
        execute_instruction(instruction, params, context)

      {:branch, metadata, [condition, true_branch, false_branch]} ->
        execute_branch(condition, true_branch, false_branch, params, context, metadata, module)

      {:converge, _metadata, [instruction]} ->
        execute_instruction(instruction, params, context)

      {:parallel, metadata, instructions} ->
        execute_parallel(instructions, params, context, metadata, module)

      _ ->
        {:error, %{type: :invalid_step, message: "Unknown step type: #{inspect(step)}"}}
    end
  end

  defp execute_instruction(instruction, params, context) do
    case Instruction.normalize_single(instruction) do
      {:ok, %Instruction{} = normalized} ->
        run_normalized_instruction(normalized, params, context)

      {:error, reason} ->
        {:error,
         %{
           type: :invalid_instruction,
           message: "Failed to normalize instruction: #{inspect(reason)}"
         }}
    end
  end

  defp run_normalized_instruction(%Instruction{} = normalized, params, context) do
    merged_params = Map.merge(params, normalized.params)
    merged_context = Map.merge(normalized.context, context)

    instruction = %{normalized | params: merged_params, context: merged_context}

    case Exec.run(instruction) do
      {:ok, result} ->
        {:ok, result}

      {:ok, result, _other} ->
        {:ok, result}

      {:error, reason} ->
        {:error, reason}

      {:error, reason, _other} ->
        {:error, reason}
    end
  end

  defp execute_branch(condition, true_branch, false_branch, params, context, _metadata, module)
       when is_boolean(condition) do
    if condition do
      module.execute_step(true_branch, params, context)
    else
      module.execute_step(false_branch, params, context)
    end
  end

  defp execute_branch(
         _condition,
         _true_branch,
         _false_branch,
         _params,
         _context,
         metadata,
         _module
       ) do
    {:error,
     %{
       type: :invalid_condition,
       message: "Invalid or unhandled condition in branch #{inspect(metadata)}"
     }}
  end

  defp execute_parallel(instructions, params, context, metadata, module) do
    max_concurrency = Keyword.get(metadata, :max_concurrency, System.schedulers_online())

    # Extract jido instance from context if present (set by parent workflow)
    jido_opts = if context[:__jido__], do: [jido: context[:__jido__]], else: []

    # Resolve supervisor based on jido: option (defaults to global)
    task_sup = Supervisors.task_supervisor(jido_opts)

    stream_opts = [
      ordered: true,
      max_concurrency: max_concurrency,
      timeout: :infinity,
      on_timeout: :kill_task
    ]

    results =
      Task.Supervisor.async_stream(
        task_sup,
        instructions,
        fn instruction ->
          execute_parallel_instruction(instruction, params, context, module)
        end,
        stream_opts
      )
      |> Enum.map(&handle_stream_result/1)

    {:ok, %{parallel_results: results}}
  end

  defp handle_stream_result({:ok, value}), do: value

  defp handle_stream_result({:exit, reason}) do
    %{error: Error.execution_error("Parallel task exited", %{reason: reason})}
  end

  defp execute_parallel_instruction(instruction, params, context, module) do
    case module.execute_step(instruction, params, context) do
      {:ok, result} -> result
      {:error, reason} -> %{error: reason}
    end
  rescue
    e ->
      %{error: Error.execution_error("Parallel step raised", %{exception: e})}
  catch
    kind, reason ->
      %{error: Error.execution_error("Parallel step caught", %{kind: kind, reason: reason})}
  end
end
