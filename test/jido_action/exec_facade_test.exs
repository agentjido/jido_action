defmodule JidoTest.ExecFacadeTest do
  use JidoTest.ActionCase, async: false

  import ExUnit.CaptureIO

  alias Jido.Exec
  alias Jido.Exec.Result
  alias Jido.Flow
  alias Jido.Instruction
  alias JidoTest.TestActions.{Add, ContextEcho, Flaky, NoParamsAction, NotAnAction, Slow}
  alias JidoTest.TestActions.WithDirective
  alias JidoTest.TestActions.ErrorAction
  alias JidoTest.TestActions.IOAction
  alias JidoTest.TestActions.KilledAction
  alias JidoTest.TestActions.StreamingAction
  alias Runic.Workflow.RunnableCompleted
  alias Runic.Workflow.RunnableDispatched
  alias Runic.Workflow.SchedulerPolicy
  alias Runic.Workflow

  def handle_telemetry_event(event, measurements, metadata, test_pid) do
    send(test_pid, {:telemetry_event, event, measurements, metadata})
  end

  describe "run/3 facade dispatch" do
    test "flow execution returns a Jido.Exec.Result" do
      flow = Flow.new(:facade_flow) |> Flow.step(:add, Add, params: %{amount: 2})

      assert {:ok, %Result{} = result} = Exec.run(flow, %{value: 3})
      assert result.status == :ok
      assert Exec.results(result).add == [%{value: 5}]
    end

    test "action execution runs as a one-step flow" do
      assert {:ok, %Result{} = result} = Exec.run(Add, %{value: 3, amount: 2})

      assert result.status == :ok
      assert Exec.results(result).add == [%{value: 5}]
      assert result.workflow.name == :add
    end

    test "instruction execution runs as a one-step flow with runtime input" do
      instruction =
        Instruction.new!(
          action: Add,
          params: %{amount: 2},
          context: %{trace_id: "instruction"}
        )

      assert {:ok, %Result{} = result} = Exec.run(instruction, %{value: 3})

      assert result.status == :ok
      assert Exec.results(result).add == [%{value: 5}]
    end

    test "raw Runic workflow execution is not supported directly" do
      workflow =
        Flow.new(:facade_workflow)
        |> Flow.step(:add, Add, params: %{amount: 2})
        |> Flow.to_workflow()

      assert {:error, %Jido.Action.Error.InvalidInputError{} = error} =
               Exec.run(workflow, %{value: 3})

      assert Exception.message(error) =~
               "expected a Jido.Action module, Jido.Instruction, or Jido.Flow"
    end

    test "unsupported executable inputs return validation errors" do
      assert {:error, %Jido.Action.Error.InvalidInputError{} = error} =
               Exec.run(%{value: 3, amount: 2})

      assert Exception.message(error) =~
               "expected a Jido.Action module, Jido.Instruction, or Jido.Flow"

      assert {:error, %Jido.Action.Error.InvalidInputError{} = error} =
               Exec.run(%{value: 3}, %{}, [])

      assert Exception.message(error) =~
               "expected a Jido.Action module, Jido.Instruction, or Jido.Flow"
    end

    test "invalid action contracts are normalized as validation errors" do
      assert {:error, %Jido.Action.Error.InvalidInputError{} = error} =
               Exec.run(NotAnAction, %{})

      assert Exception.message(error) =~ "module is not a valid Jido action"

      instruction = Instruction.new!(action: NotAnAction)

      assert {:error, %Jido.Action.Error.InvalidInputError{} = error} =
               Exec.run(instruction)

      assert Exception.message(error) =~ "module is not a valid Jido action"
    end

    test "one-arity run handles actions, instructions, and already idle flows" do
      instruction = Instruction.new!(action: NoParamsAction)

      assert {:ok, %Result{status: :ok, cycles: 0}} = Exec.run(Flow.new(:idle_run))

      assert {:ok, %Result{} = action_result} = Exec.run(NoParamsAction)
      assert Exec.results(action_result).no_params_action == [%{result: "No params"}]

      assert {:ok, %Result{} = instruction_result} = Exec.run(instruction)
      assert Exec.results(instruction_result).no_params_action == [%{result: "No params"}]
    end

    test "three-arity action and instruction execution pass runtime options" do
      instruction =
        Instruction.new!(
          action: ContextEcho,
          params: %{value: 7},
          context: %{static: true}
        )

      assert {:ok, %Result{} = instruction_result} =
               Exec.run(instruction, %{}, run_context: %{context_echo: %{runtime: true}})

      assert Exec.results(instruction_result).context_echo == [
               %{value: 7, static: true, runtime: true}
             ]

      assert {:ok, %Result{} = action_result} =
               Exec.run(ContextEcho, %{value: 8},
                 run_context: %{context_echo: %{static: false, runtime: true}}
               )

      assert Exec.results(action_result).context_echo == [
               %{value: 8, static: false, runtime: true}
             ]
    end
  end

  describe "step/3 facade dispatch" do
    test "executes one dispatch cycle for actions, instructions, and flows" do
      instruction = Instruction.new!(action: Add, params: %{amount: 2})
      flow = Flow.new(:step_flow) |> Flow.step(:add, Add, params: %{amount: 2})

      assert {:ok, %Result{} = action_result} = Exec.step(Add, %{value: 3, amount: 2})
      assert {:ok, %Result{} = instruction_result} = Exec.step(instruction, %{value: 3})
      assert {:ok, %Result{} = flow_result} = Exec.step(flow, %{value: 3})

      assert Exec.results(action_result).add == [%{value: 5}]
      assert Exec.results(instruction_result).add == [%{value: 5}]
      assert Exec.results(flow_result).add == [%{value: 5}]
    end

    test "one-arity step handles actions, instructions, flows, and unsupported input" do
      instruction = Instruction.new!(action: NoParamsAction)

      assert {:ok, %Result{status: :ok}} = Exec.step(Flow.new(:idle_step))

      assert {:ok, %Result{} = action_result} = Exec.step(NoParamsAction)
      assert Exec.results(action_result).no_params_action == [%{result: "No params"}]

      assert {:ok, %Result{} = instruction_result} = Exec.step(instruction)
      assert Exec.results(instruction_result).no_params_action == [%{result: "No params"}]

      assert {:error, %Jido.Action.Error.InvalidInputError{} = error} = Exec.step(%{})

      assert Exception.message(error) =~
               "expected a Jido.Action module, Jido.Instruction, or Jido.Flow"
    end

    test "unsupported step arities return validation errors" do
      assert {:error, %Jido.Action.Error.InvalidInputError{} = error} = Exec.step(%{}, %{})

      assert Exception.message(error) =~
               "expected a Jido.Action module, Jido.Instruction, or Jido.Flow"

      assert {:error, %Jido.Action.Error.InvalidInputError{} = error} = Exec.step(%{}, %{}, [])

      assert Exception.message(error) =~
               "expected a Jido.Action module, Jido.Instruction, or Jido.Flow"
    end

    test "failed action steps return error results from one dispatch cycle" do
      flow = Flow.from_action(ErrorAction, %{type: :error}, name: :bad_step)

      assert {:error, %Result{status: :error, cycles: 1, error: error}} =
               silence_logger(fn -> Exec.step(flow, %{}) end)

      assert error.details.node == :bad_step

      assert {:error, %Jido.Action.Error.InvalidInputError{} = invalid} =
               Exec.step(NotAnAction)

      assert Exception.message(invalid) =~ "module is not a valid Jido action"
    end

    test "three-arity step accepts runtime context for flows, instructions, and actions" do
      instruction = Instruction.new!(action: ContextEcho, params: %{value: 3})
      flow = Flow.from_action(ContextEcho, %{value: 4}, name: :context_echo)

      assert {:ok, %Result{} = flow_result} =
               Exec.step(flow, %{}, run_context: %{context_echo: %{static: false, runtime: true}})

      assert {:ok, %Result{} = instruction_result} =
               Exec.step(instruction, %{},
                 run_context: %{context_echo: %{static: false, runtime: true}}
               )

      assert {:ok, %Result{} = action_result} =
               Exec.step(ContextEcho, %{value: 5},
                 run_context: %{context_echo: %{static: false, runtime: true}}
               )

      assert Exec.results(flow_result).context_echo == [%{value: 4, static: false, runtime: true}]

      assert Exec.results(instruction_result).context_echo == [
               %{value: 3, static: false, runtime: true}
             ]

      assert Exec.results(action_result).context_echo == [
               %{value: 5, static: false, runtime: true}
             ]
    end
  end

  describe "resume/3" do
    test "continues successful and max-cycle results" do
      flow =
        Flow.new(:resume_flow)
        |> Flow.step(:add, Add, params: %{amount: 2})

      assert {:ok, %Result{} = result} = Exec.run(flow, %{value: 3})
      assert {:ok, %Result{} = resumed} = Exec.resume(result, %{value: 4})

      assert %{add: productions} = Exec.results(resumed)
      assert %{value: 5} in productions
      assert %{value: 6} in productions

      bounded =
        Flow.new(:bounded_resume)
        |> Flow.step(:add, Add, params: %{amount: 1})
        |> Flow.step(:again, Add, params: %{amount: 1}, after: :add)

      assert {:error, %Result{status: :max_cycles} = maxed} =
               Exec.run(bounded, %{value: 1}, max_cycles: 1)

      assert {:ok, %Result{} = resumed_maxed} = Exec.resume(maxed, nil)
      assert Exec.results(resumed_maxed).again == [%{value: 3}]
    end

    test "rejects failed results and non-result inputs" do
      flow = Flow.new(:failed_resume) |> Flow.step(:bad, ErrorAction, params: %{type: :error})

      assert {:error, %Result{status: :error} = result} =
               silence_logger(fn -> Exec.run(flow, %{}) end)

      assert {:error, %Jido.Action.Error.InvalidInputError{} = error} =
               Exec.resume(result, %{})

      assert Exception.message(error) =~ "cannot resume failed execution result"

      assert {:error, %Jido.Action.Error.InvalidInputError{} = error} =
               Exec.resume(flow, %{})

      assert Exception.message(error) =~ "expected a Jido.Exec.Result"

      assert {:error, %Jido.Action.Error.InvalidInputError{} = error} =
               Exec.resume(flow, %{}, [])

      assert Exception.message(error) =~ "expected a Jido.Exec.Result"
    end
  end

  describe "runtime options" do
    test "validates run context and max cycle options" do
      flow = Flow.from_action(Add, %{amount: 1}, name: :add)

      assert {:error, %Jido.Action.Error.InvalidInputError{} = error} =
               Exec.run(flow, %{value: 1}, run_context: [])

      assert Exception.message(error) == ":run_context must be a map"
      assert error.details.run_context == []

      assert {:error, %Jido.Action.Error.InvalidInputError{} = error} =
               Exec.run(flow, %{value: 1}, max_cycles: 0)

      assert Exception.message(error) == ":max_cycles must be a positive integer"
      assert error.details.max_cycles == 0
    end

    test "supports checkpoints, deadline options, and explicit Fact input" do
      parent = self()

      flow =
        Flow.new(:option_flow)
        |> Flow.step(:add, Add, params: %{amount: 2})
        |> Flow.step(:again, Add, params: %{amount: 1}, after: :add)

      fact = Runic.Workflow.Fact.new(value: %{value: 3})

      assert {:ok, %Result{} = result} =
               Exec.run(flow, fact,
                 deadline_ms: 1_000,
                 checkpoint: fn workflow ->
                   send(parent, {:checkpoint, Workflow.raw_productions(workflow)})
                 end
               )

      assert Exec.results(result).again == [%{value: 6}]
      assert_receive {:checkpoint, [%{value: 5}]}
      assert_receive {:checkpoint, productions}
      assert %{value: 6} in productions

      deadline_at = System.monotonic_time(:millisecond) + 1_000

      assert {:ok, %Result{} = deadline_result} =
               Exec.run(Add, %{value: 1, amount: 1}, deadline_ms: 1, deadline_at: deadline_at)

      assert Exec.results(deadline_result).add == [%{value: 2}]
    end

    test "accepts scheduler policy structs and keyword runtime overrides" do
      with_flaky_key(fn key ->
        flow =
          Flow.new(:struct_policy)
          |> Flow.step(:flaky, Flaky)
          |> Flow.policy(:flaky, SchedulerPolicy.fast_fail())

        assert {:error, %Result{status: :error}} =
                 silence_logger(fn -> Exec.run(flow, %{key: key}) end)
      end)

      with_flaky_key(fn key ->
        flow =
          Flow.new(:keyword_policy)
          |> Flow.step(:flaky, Flaky)
          |> Flow.policy(:flaky, %{max_retries: 0, backoff: :none})

        assert {:ok, %Result{} = result} =
                 silence_logger(fn ->
                   Exec.run(flow, %{key: key},
                     scheduler_policies: [{:flaky, [max_retries: 1, backoff: :none]}],
                     scheduler_policies_mode: :replace
                   )
                 end)

        assert Exec.results(result).flaky == [%{attempts: 2}]
      end)

      with_flaky_key(fn key ->
        flow = Flow.new(:runtime_struct_policy) |> Flow.step(:flaky, Flaky)

        assert {:error, %Result{status: :error}} =
                 silence_logger(fn ->
                   Exec.run(flow, %{key: key},
                     scheduler_policies: [{:flaky, SchedulerPolicy.fast_fail()}]
                   )
                 end)
      end)
    end

    test "validates scheduler policy option shapes" do
      flow = Flow.from_action(Add, %{amount: 1}, name: :add)

      assert {:error, %Jido.Action.Error.InvalidInputError{} = error} =
               Exec.run(flow, %{value: 1}, scheduler_policies: :bad)

      assert Exception.message(error) == ":scheduler_policies must be a list"
      assert error.details.scheduler_policies == :bad

      assert {:error, %Jido.Action.Error.InvalidInputError{} = error} =
               Exec.run(flow, %{value: 1}, scheduler_policies: [{:add, :bad}])

      assert Exception.message(error) =~
               ":scheduler_policies must be a list of {matcher, policy} tuples"

      assert error.details.scheduler_policies == [{:add, :bad}]

      assert {:error, %Jido.Action.Error.InvalidInputError{} = error} =
               Exec.run(flow, %{value: 1}, scheduler_policies: [:bad_entry])

      assert Exception.message(error) =~
               ":scheduler_policies must be a list of {matcher, policy} tuples"

      assert error.details.scheduler_policies == [:bad_entry]

      assert {:error, %Jido.Action.Error.InvalidInputError{} = error} =
               Exec.step(flow, %{value: 1}, scheduler_policies_mode: :bad_mode)

      assert Exception.message(error) == ":scheduler_policies_mode must be :merge or :replace"
      assert error.details.scheduler_policies_mode == :bad_mode
    end
  end

  describe "action invocation boundary" do
    test "rejects non-tuple action return values without running output validation" do
      module = unique_module("WeirdReturnAction")

      create_module(
        module,
        quote do
          use Jido.Action,
            name: "weird_return_action",
            schema: Zoi.object(%{value: Zoi.any()}),
            output_schema: Zoi.object(%{required: Zoi.string()})

          @impl true
          @dialyzer {:nowarn_function, run: 2}
          def run(%{value: value}, _context), do: value
        end
      )

      for value <- [:ok, "result", %{value: 1}, [1, 2, 3]] do
        flow = Flow.from_action(module, %{value: value}, name: :weird_return)

        assert {:error,
                %Result{
                  status: :error,
                  error: %Jido.Action.Error.ExecutionFailureError{} = error
                }} =
                 silence_logger(fn ->
                   Exec.run(flow, %{})
                 end)

        assert error.details.node == :weird_return
        assert %Jido.Action.Error.ExecutionFailureError{} = reason = error.details.reason
        assert reason.message == "unexpected action return shape"
        assert reason.details.value == value
      end
    end

    test "contains thrown values from actions" do
      flow = Flow.from_action(ErrorAction, %{type: :throw}, name: :throwing_action)

      assert {:error, %Result{status: :error, error: error}} =
               silence_logger(fn ->
                 Exec.run(flow, %{})
               end)

      assert error.details.node == :throwing_action
      assert %Jido.Action.Error.ExecutionFailureError{} = reason = error.details.reason
      assert reason.message == "action exited during invocation"
      assert reason.details.kind == :throw
      assert reason.details.reason == "Action threw an error"
    end

    test "contains untrappable action exits without taking down the caller" do
      flow = Flow.from_action(KilledAction, %{}, name: :killed_action)

      assert {:error, %Result{status: :error, error: error}} =
               silence_logger(fn ->
                 Exec.run(flow, %{})
               end)

      assert error.details.node == :killed_action
      assert %Jido.Action.Error.ExecutionFailureError{} = reason = error.details.reason
      assert reason.message == "runnable execution exited"
      assert reason.details.kind == :exit
      assert reason.details.reason == :killed
    end

    test "contains untrappable action exits from timeout-isolated policy tasks" do
      flow =
        KilledAction
        |> Flow.from_action(%{}, name: :killed_action)
        |> Flow.policy(:killed_action, %{timeout_ms: 1_000})

      assert {:error, %Result{status: :error, error: error}} =
               silence_logger(fn ->
                 Exec.run(flow, %{})
               end)

      assert error.details.node == :killed_action
      assert %Jido.Action.Error.ExecutionFailureError{} = reason = error.details.reason
      assert reason.message == "runnable execution exited"
      assert reason.details.kind == :exit
      assert reason.details.reason == :killed
    end

    test "streams survive flow execution and remain lazy" do
      flow =
        Flow.from_action(StreamingAction, %{chunk_size: 2, total_items: 10}, name: :streaming)

      assert {:ok, %Result{} = result} = Exec.run(flow, %{})
      assert [%{stream: stream}] = result.results.streaming
      assert %Stream{} = stream
      assert Enum.to_list(stream) == [3, 7, 11, 15, 19]
    end

    test "routes action IO to the caller while executing under timeout policy" do
      flow =
        IOAction
        |> Flow.from_action(%{input: "test output", operation: :puts}, name: :io_action)
        |> Flow.policy(:io_action, %{timeout_ms: 1_000})

      io =
        capture_io(fn ->
          assert {:ok, %Result{} = result} = Exec.run(flow, %{})
          assert result.results.io_action == [%{input: "test output"}]
        end)

      assert io == "test output\n"
    end
  end

  describe "action telemetry boundary" do
    setup do
      handler_id = "jido-action-telemetry-#{System.unique_integer([:positive])}"
      test_pid = self()

      :ok =
        :telemetry.attach_many(
          handler_id,
          [[:jido, :action, :start], [:jido, :action, :stop]],
          &__MODULE__.handle_telemetry_event/4,
          test_pid
        )

      on_exit(fn -> :telemetry.detach(handler_id) end)
      :ok
    end

    test "emits low-cardinality action spans for Jido action runnables" do
      flow =
        Flow.new(:telemetry_flow)
        |> Flow.step(:add, Add, params: %{amount: 2})
        |> Flow.step(:again, Add, params: %{amount: 1}, after: :add)

      assert {:ok, %Result{} = result} = Exec.run(flow, %{value: 3}, jido: :tenant_a)
      assert Exec.results(result).again == [%{value: 6}]

      assert_receive {:telemetry_event, [:jido, :action, :start], _measurements, start_metadata}

      assert Map.drop(start_metadata, [:telemetry_span_context]) == %{
               action: Add,
               jido: :tenant_a
             }

      refute Map.has_key?(start_metadata, :params)
      refute Map.has_key?(start_metadata, :context)

      assert_receive {:telemetry_event, [:jido, :action, :stop], _measurements, stop_metadata}

      assert Map.drop(stop_metadata, [:telemetry_span_context]) == %{
               action: Add,
               jido: :tenant_a,
               outcome: :ok
             }

      assert_receive {:telemetry_event, [:jido, :action, :start], _measurements, second_start}

      assert Map.drop(second_start, [:telemetry_span_context]) == %{
               action: Add,
               jido: :tenant_a
             }

      assert_receive {:telemetry_event, [:jido, :action, :stop], _measurements, second_stop}

      assert Map.drop(second_stop, [:telemetry_span_context]) == %{
               action: Add,
               jido: :tenant_a,
               outcome: :ok
             }
    end

    test "emits error metadata for failed action runnables" do
      flow = Flow.from_action(ErrorAction, %{type: :error}, name: :failing_action)

      assert {:error, %Result{status: :error}} =
               silence_logger(fn -> Exec.run(flow, %{}) end)

      assert_receive {:telemetry_event, [:jido, :action, :start], _measurements, start_metadata}

      assert Map.drop(start_metadata, [:telemetry_span_context]) == %{action: ErrorAction}

      assert_receive {:telemetry_event, [:jido, :action, :stop], _measurements, stop_metadata}

      assert Map.drop(stop_metadata, [:telemetry_span_context]) == %{
               action: ErrorAction,
               outcome: :error,
               error_type: :execution_error,
               retryable?: true
             }
    end

    test "emits timeout metadata from the Runic policy boundary" do
      flow =
        Flow.from_action(Slow, %{delay: 50}, name: :slow)
        |> Flow.policy(:slow, %{timeout_ms: 10, max_retries: 0, backoff: :none})

      assert {:error, %Result{status: :error}} =
               silence_logger(fn -> Exec.run(flow, %{}) end)

      assert_receive {:telemetry_event, [:jido, :action, :start], _measurements, start_metadata}

      assert Map.drop(start_metadata, [:telemetry_span_context]) == %{action: Slow}

      assert_receive {:telemetry_event, [:jido, :action, :stop], _measurements, stop_metadata}

      assert Map.drop(stop_metadata, [:telemetry_span_context]) == %{
               action: Slow,
               outcome: :error,
               error_type: :timeout,
               retryable?: true
             }
    end

    test "emits directive and deadline metadata from worker results" do
      directive_flow = Flow.from_action(WithDirective, %{value: 1}, name: :with_directive)

      assert {:ok, %Result{}} = Exec.run(directive_flow, %{})

      assert_receive {:telemetry_event, [:jido, :action, :start], _measurements, _metadata}
      assert_receive {:telemetry_event, [:jido, :action, :stop], _measurements, stop_metadata}

      assert Map.drop(stop_metadata, [:telemetry_span_context]) == %{
               action: WithDirective,
               outcome: :ok,
               directive?: true
             }

      deadline_flow = Flow.from_action(Add, %{amount: 1}, name: :add)

      assert {:error, %Result{status: :error}} =
               silence_logger(fn ->
                 Exec.run(deadline_flow, %{value: 1},
                   deadline_at: System.monotonic_time(:millisecond) - 1
                 )
               end)

      assert_receive {:telemetry_event, [:jido, :action, :start], _measurements, _metadata}
      assert_receive {:telemetry_event, [:jido, :action, :stop], _measurements, deadline_metadata}

      assert Map.drop(deadline_metadata, [:telemetry_span_context]) == %{
               action: Add,
               outcome: :error,
               error_type: :timeout,
               retryable?: true
             }
    end
  end

  describe "result schema" do
    test "result construction is schema validated" do
      workflow = Workflow.new(:schema_result)

      result = Result.new(workflow, :ok, results: %{})

      assert %Result{status: :ok, results: %{}, events: [], cycles: 0, error: nil} = result
      assert result.workflow == workflow

      assert_raise ArgumentError, ~r/invalid execution result/, fn ->
        apply(Result, :new, [workflow, :bogus])
      end

      assert_raise ArgumentError, ~r/invalid execution result/, fn ->
        Result.new(workflow, :ok, cycles: -1)
      end
    end
  end

  describe "result helpers" do
    test "extract results, events, summary, and provenance from execution results" do
      flow =
        Flow.new(:helper_flow)
        |> Flow.step(:add, Add, params: %{amount: 2})
        |> Flow.step(:again, Add, params: %{amount: 1}, after: :add)

      assert {:ok, %Result{} = result} = Exec.run(flow, %{value: 3})

      assert Exec.results(result, raw: true) == [%{value: 5}, %{value: 6}]
      assert Exec.results(result, components: [:add]) == %{add: %{value: 5}}
      assert Exec.results(result, refresh: true) == %{add: [%{value: 5}], again: [%{value: 6}]}
      assert is_list(Exec.events(result, refresh: true))

      assert %{
               status: :ok,
               cycles: 2,
               error: nil,
               total_nodes: 2,
               facts_produced: facts_produced,
               productions: 2,
               satisfied?: true
             } = Exec.summary(result)

      assert facts_produced >= 3

      produced =
        result.workflow
        |> Workflow.facts()
        |> Enum.find(fn fact -> fact.value == %{value: 6} end)

      assert %Runic.Workflow.Fact{} = produced
      assert {:ok, chain} = Exec.provenance(result, produced.hash)
      assert Enum.map(chain, & &1.value) == [%{value: 3}, %{value: 5}, %{value: 6}]
      assert {:error, :not_found} = Exec.provenance(result, :missing_fact)
    end

    test "reject non-result values in result helper functions" do
      assert {:error, %Jido.Action.Error.InvalidInputError{} = error} = Exec.results(:not_result)
      assert Exception.message(error) == "expected a Jido.Exec.Result"

      assert {:error, %Jido.Action.Error.InvalidInputError{} = error} =
               Exec.results(:not_result, [])

      assert Exception.message(error) == "expected a Jido.Exec.Result"

      assert {:error, %Jido.Action.Error.InvalidInputError{} = error} = Exec.events(:not_result)
      assert Exception.message(error) == "expected a Jido.Exec.Result"

      assert {:error, %Jido.Action.Error.InvalidInputError{} = error} = Exec.summary(:not_result)
      assert Exception.message(error) == "expected a Jido.Exec.Result"

      assert {:error, %Jido.Action.Error.InvalidInputError{} = error} =
               Exec.provenance(:not_result, :hash)

      assert Exception.message(error) == "expected a Jido.Exec.Result"
    end
  end

  describe "Runic flow policy integration" do
    test "named flow policy applies without Jido app defaults" do
      with_flaky_key(fn key ->
        flow =
          Flow.new(:workflow_policy)
          |> Flow.step(:flaky, Flaky)
          |> Flow.policy(:flaky, %{max_retries: 0, backoff: :none})

        silence_logger(fn ->
          assert {:error, %Result{status: :error}} = Exec.run(flow, %{key: key})
        end)
      end)
    end

    test "named flow policy can retry a matching component" do
      with_flaky_key(fn key ->
        flow =
          Flow.new(:step_policy)
          |> Flow.step(:flaky, Flaky)
          |> Flow.policy(:flaky, %{max_retries: 1, backoff: :none})

        {:ok, %Result{workflow: workflow}} =
          silence_logger(fn ->
            Exec.run(flow, %{key: key})
          end)

        assert Workflow.raw_productions(workflow, :flaky) == [%{attempts: 2}]
      end)
    end

    test "runtime scheduler_policies override named flow policies" do
      with_flaky_key(fn key ->
        flow =
          Flow.new(:runtime_policy)
          |> Flow.step(:flaky, Flaky)
          |> Flow.policy(:flaky, %{max_retries: 1, backoff: :none})

        silence_logger(fn ->
          assert {:error, %Result{status: :error}} =
                   Exec.run(flow, %{key: key},
                     scheduler_policies: [{:flaky, %{max_retries: 0, backoff: :none}}]
                   )
        end)
      end)
    end

    test "durable step policy exposes Runic runnable lifecycle events" do
      flow =
        Flow.new(:durable_policy)
        |> Flow.step(:add, Add, params: %{amount: 2})
        |> Flow.policy(:add, %{execution_mode: :durable})

      assert {:ok, %Result{} = result} = Exec.run(flow, %{value: 3})

      events = Exec.events(result)
      assert Enum.any?(events, &match?(%RunnableDispatched{}, &1))
      assert Enum.any?(events, &match?(%RunnableCompleted{}, &1))
    end
  end

  defp with_flaky_key(fun) do
    key = System.unique_integer([:positive])
    term_key = {Flaky, key}
    :persistent_term.erase(term_key)

    try do
      fun.(key)
    after
      :persistent_term.erase(term_key)
    end
  end
end
