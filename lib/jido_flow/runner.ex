defmodule Jido.Flow.Runner do
  @moduledoc """
  Behavior defining how a Jido.Flow Runner executes steps.

  A Jido.Flow Runner is responsible for executing `Jido.Flow.Step.execute/2` 
  for given runnables in an arbitrary runtime execution context.

  Since every runnable returned by `Jido.Flow.next_runnables/2` can run in 
  parallel, a Runner may choose how to optimize that workload.

  Unlike Piper.Runner, Jido.Flow.Runner integrates with Jido's error handling
  and supports both individual and batch execution modes.

  ## Examples

  ### Simple Sequential Runner

      defmodule MyApp.SequentialRunner do
        @behaviour Jido.Flow.Runner

        @impl true
        def run(runnable) when is_tuple(runnable) do
          run([runnable])
        end

        @impl true
        def run(runnables) when is_list(runnables) do
          results = 
            Enum.map(runnables, fn {step, context} ->
              Jido.Flow.Step.execute(step, context)
            end)

          {:ok, results}
        end
      end

  ### Async Task Runner

      defmodule MyApp.TaskAsyncRunner do
        @behaviour Jido.Flow.Runner

        @impl true
        def run(runnable) when is_tuple(runnable) do
          run([runnable])
        end

        @impl true  
        def run(runnables) when is_list(runnables) do
          tasks = 
            Enum.map(runnables, fn {step, context} ->
              Task.async(fn ->
                case Jido.Flow.Step.execute(step, context) do
                  {:ok, result_context} ->
                    # Publish success to event system
                    Phoenix.PubSub.broadcast(MyApp.PubSub, "flow_results", {:step_completed, step.name, result_context})
                    {:ok, result_context}

                  {:error, error} ->
                    # Publish error to event system
                    Phoenix.PubSub.broadcast(MyApp.PubSub, "flow_errors", {:step_failed, step.name, error})
                    {:error, error}
                end
              end)
            end)

          results = Task.await_many(tasks, 10_000)
          {:ok, results}
        end
      end

  ### GenServer Pool Runner

      defmodule MyApp.PoolRunner do
        @behaviour Jido.Flow.Runner

        @impl true
        def run(runnable) when is_tuple(runnable) do
          run([runnable])
        end

        @impl true
        def run(runnables) when is_list(runnables) do
          # Distribute work across a pool of GenServer workers
          pool_size = System.schedulers_online()
          
          runnables
          |> Enum.chunk_every(div(length(runnables), pool_size) + 1)
          |> Enum.map(fn chunk ->
            Task.async(fn ->
              Enum.map(chunk, fn {step, context} ->
                Jido.Flow.Step.execute(step, context)
              end)
            end)
          end)
          |> Task.await_many()
          |> List.flatten()
          |> then(&{:ok, &1})
        end
      end
  """

  alias Jido.Flow.{Step, Context}
  alias Jido.Action.Error

  @type runnable() :: {Step.t(), Context.t()}
  @type execution_result() :: {:ok, Context.t()} | {:error, Error.t()}
  @type batch_result() :: {:ok, [execution_result()]} | {:error, Error.t()}

  @doc """
  Executes one or more runnables.

  ## Parameters

  - `runnable` - A single runnable tuple `{step, context}` or list of runnables
  
  ## Returns

  - `{:ok, results}` where results is a list of execution results
  - `{:error, error}` if the runner itself fails (not individual step failures)

  ## Note

  Individual step failures should be returned in the results list as 
  `{:error, error}` tuples, not cause the entire batch to fail.
  Only runner-level failures (like timeout, pool exhaustion, etc.) 
  should return `{:error, error}` for the entire batch.
  """
  @callback run(runnable() | [runnable()]) :: batch_result()
end
