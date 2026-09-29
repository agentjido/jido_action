Code.require_file("../support/runtime.exs", __DIR__)
Code.require_file("../support/fuzz.exs", __DIR__)

defmodule JidoActionTest.Property.Action.BoundaryContractTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  alias Jido.{Exec, Flow}
  alias Jido.Action.{Error, Output}
  alias Jido.Flow.{Ref, Step}
  alias JidoActionTest.Property.{Fuzz, Runtime}

  defmodule Validated do
    use Jido.Action,
      name: "property_validated",
      schema: Zoi.object(%{value: Zoi.integer()}),
      output_schema: Zoi.object(%{value: Zoi.integer()})

    @impl true
    def run(params, context) do
      send(context.observer, {context.token, :call, params, self()})
      {:ok, %{value: Map.get(context, :output, params.value)}, [:request]}
    end
  end

  defmodule Failure do
    use Jido.Action, name: "property_failure"
    @impl true
    def run(%{mode: mode, value: value}, context) do
      send(context.observer, {context.token, :call, mode, self()})

      case mode do
        :raise -> raise ArgumentError, "property failure #{value}"
        :throw -> throw({:property_failure, value})
        :exit -> exit({:property_failure, value})
        :return -> {:error, {:property_failure, value}, [:discard]}
        :invalid -> {:unknown, value}
      end
    end
  end

  defmodule Result do
    use Jido.Action, name: "property_result"
    @impl true
    def run(%{output: output, effects: effects}, _), do: {:ok, output, effects}
  end

  @tag contracts: ["ACT-001"]
  @tag contract_cases: [
         "ACT-001/missing",
         "ACT-001/string",
         "ACT-001/list",
         "ACT-001/nil",
         "ACT-001/root-extra"
       ]
  property "all invalid input classes fail before work in direct and Flow calls" do
    check all(value <- integer(-100..100), max_runs: 30) do
      assert_input(value)
    end
  end

  @tag contracts: ["ACT-002", "ERROR-001", "EFFECT-002"]
  @tag contract_cases: [
         "ACT-002/raise",
         "ACT-002/throw",
         "ACT-002/exit",
         "ACT-002/returned-error",
         "ACT-002/invalid-return",
         "ERROR-001/stacktrace-omitted"
       ]
  property "every callback failure form retains public failure data without effects" do
    check all(value <- integer(-100..100), max_runs: 25) do
      assert_callback_failures(value)
    end
  end

  @tag contracts: ["ACT-003", "EFFECT-002"]
  @tag contract_cases: ["ACT-003/after-callback", "EFFECT-002/output-validation"]
  property "output validation runs after work and discards requested effects on rejection" do
    check all(value <- integer(-100..100), max_runs: 25) do
      assert_output_validation(value)
    end
  end

  @tag contracts: ["ACT-004", "EFFECT-001"]
  @tag contract_cases: [
         "ACT-004/raw",
         "ACT-004/batch",
         "ACT-004/opaque",
         "ACT-004/lazy-stream",
         "EFFECT-001/duplicate-requests"
       ]
  property "output envelopes preserve data and keep streams lazy" do
    check all(
            values <- list_of(integer(-20..20), min_length: 1, max_length: 6),
            max_runs: 30
          ) do
      assert_envelopes(values)
    end
  end

  @tag contracts: ["ACT-004", "EFFECT-002"]
  @tag contract_cases: [
         "ACT-004/unwrapped-raw",
         "EFFECT-002/nil-effects",
         "EFFECT-002/map-effects",
         "EFFECT-002/improper-effects"
       ]
  property "raw success and malformed effect batches fail through both boundaries" do
    check all(value <- integer(-100..100), max_runs: 25) do
      assert_effects(value)
    end
  end

  @tag :fuzz
  @tag max_runs: 250, max_run_time: 300_000, timeout: 900_000, max_items: 30
  @tag contracts: [
         "ACT-001",
         "ACT-002",
         "ACT-003",
         "ACT-004",
         "ERROR-001",
         "EFFECT-001",
         "EFFECT-002"
       ]
  @tag contract_cases: [
         "ACT-001/fuzz-invalid-input",
         "ACT-002/fuzz-failure-forms",
         "ACT-003/fuzz-output-validation",
         "ACT-004/fuzz-envelopes",
         "ERROR-001/fuzz-retry-policy",
         "EFFECT-001/fuzz-duplicates",
         "EFFECT-002/fuzz-invalid-effects"
       ]
  test "fuzz: Action boundaries retain validation order errors envelopes and effects", context do
    generator =
      fixed_map(%{
        "value" => integer(),
        "values" => list_of(integer(), max_length: context.max_items)
      })

    examples = [%{"value" => 0, "values" => []}, %{"value" => -1, "values" => [1, 1, -1]}]

    Fuzz.check(
      "action_boundaries",
      generator,
      Map.to_list(context) ++ [examples: examples],
      fn sample ->
        value = sample["value"]
        assert_input(value)
        assert_callback_failures(value)
        assert_output_validation(value)
        assert_envelopes(sample["values"])
        assert_effects(value)

        for retry <- [false, true],
            {constructor, type, allowed} <- [
              {:validation_error, :validation_error, false},
              {:execution_error, :execution_error, true},
              {:timeout_error, :timeout, true},
              {:config_error, :configuration_error, false},
              {:internal_error, :internal_error, false}
            ] do
          details = %{value: sample["values"], retry: retry}
          error = apply(Error, constructor, ["fuzz error #{value}", details])

          expected = %{
            type: type,
            message: "fuzz error #{value}",
            details: details,
            retryable?: retry and allowed
          }

          assert Error.to_map(error) == expected
          assert Error.to_map({:error, error, [:discard]}) == expected
          assert Error.retryable?(error) == (retry and allowed)
        end

        ["all-failure-forms", "all-envelopes", "items:#{length(sample["values"])}"]
      end
    )
  end

  defp flow(action) do
    Flow.new!(
      name: "boundary",
      components: [Step.new!(name: "work", action: action, params: Ref.input([]))],
      output: Ref.result("work")
    )
  end

  defp assert_input(value) do
    for input <- [%{}, %{value: Integer.to_string(value)}, %{value: [value]}, %{value: nil}],
        target <- [Validated, flow(Validated)] do
      Runtime.with_context(fn context ->
        assert {:error, %Error.InvalidInputError{}} =
                 Exec.run(target, input, context, Runtime.options(context))

        Runtime.assert_calls(context, [])
      end)
    end

    # Action root validation preserves undeclared fields.
    Runtime.with_context(fn context ->
      input = %{value: value, extra: %{value: value}}
      assert {:ok, %{value: ^value}, [:request]} = Exec.run(Validated, input, context)
      Runtime.assert_calls(context, [input])
    end)
  end

  defp assert_callback_failures(value) do
    for mode <- [:raise, :throw, :exit, :return, :invalid],
        {target, concurrency} <- [{Failure, 1}, {flow(Failure), 1}, {flow(Failure), 3}] do
      Runtime.with_context(fn context ->
        assert {:error, %Error.ExecutionFailureError{} = error} =
                 Exec.run(
                   target,
                   %{mode: mode, value: value},
                   context,
                   Runtime.options(context, concurrency)
                 )

        case mode do
          :raise ->
            assert error.message == "property failure #{value}"
            assert error.details.exception == ArgumentError

          mode when mode in [:throw, :exit, :return] ->
            assert error.details.reason == {:property_failure, value}

          :invalid ->
            assert error.details.result == {:unknown, value}
        end

        if mode in [:raise, :throw, :exit] do
          assert %Splode.Stacktrace{stacktrace: frames} = error.stacktrace
          assert Enum.any?(frames, &match?({Failure, :run, 2, _}, &1))
        end

        public = Error.to_map(error)
        refute Map.has_key?(public, :stacktrace)
        refute Error.retryable?(error)
        Runtime.assert_calls(context, [mode])
      end)
    end
  end

  defp assert_output_validation(value) do
    for target <- [Validated, flow(Validated)] do
      Runtime.with_context(fn context ->
        context = Map.put(context, :output, Integer.to_string(value))

        assert {:error, %Error.InvalidInputError{}} =
                 Exec.run(target, %{value: value}, context, Runtime.options(context))

        Runtime.assert_calls(context, [%{value: value}])
      end)
    end
  end

  defp assert_envelopes(values) do
    Runtime.with_context(fn context ->
      owner = context.observer
      ref = context.token

      stream =
        Stream.map(values, fn value ->
          send(owner, {ref, :consumed, value})
          value
        end)

      for output <- [
            Output.raw(values),
            Output.batch(values),
            Output.opaque({:values, values}),
            Output.stream(stream, meta: %{source: "property"})
          ],
          target <- [Result, flow(Result)] do
        effects = [values, :same, :same]

        assert Exec.run(
                 target,
                 %{output: output, effects: effects},
                 context,
                 Runtime.options(context)
               ) == {:ok, output, effects}

        refute_received {^ref, :consumed, _}
      end

      assert Enum.to_list(stream) == values
      for value <- values, do: assert_received({^ref, :consumed, ^value})
      refute_received {^ref, :consumed, _}
    end)
  end

  defp assert_effects(value) do
    for target <- [Result, flow(Result)] do
      assert {:error, %Error.ExecutionFailureError{}} =
               Exec.run(target, %{output: value, effects: []})

      for effects <- [nil, %{value: value}, [value | :improper]] do
        assert {:error, %Error.ExecutionFailureError{details: %{reason: :invalid_effects}}} =
                 Exec.run(target, %{output: %{value: value}, effects: effects})
      end

      assert Exec.run(target, %{output: %{value: value}, effects: []}) ==
               {:ok, %{value: value}}
    end
  end
end
