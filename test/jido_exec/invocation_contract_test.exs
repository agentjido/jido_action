defmodule JidoActionTest.Exec.InvocationContractTest do
  use ExUnit.Case, async: true

  alias Jido.Action.Output
  alias Jido.Exec
  alias Jido.Exec.Error.InterruptedError
  alias Jido.Exec.Invocation
  alias Jido.Exec.Invocation.Runtime
  alias Jido.Exec.Options
  alias Jido.Flow
  alias Jido.Flow.Step

  defmodule Action do
    use Jido.Action, name: "invocation_contract_action"

    @impl true
    def run(params, _context), do: {:ok, params}
  end

  defmodule Host do
    @behaviour Invocation

    @impl true
    def before_invoke(invocation, owner) do
      send(owner, {:before_invoke, invocation})
      :execute
    end

    @impl true
    def after_invoke(receipt, owner) do
      send(owner, {:after_invoke, receipt})
      :ok
    end
  end

  defmodule MissingBeforeHost do
    def after_invoke(_receipt, _ref), do: :ok
  end

  defmodule MissingAfterHost do
    def before_invoke(_invocation, _ref), do: :execute
  end

  defmodule ReturnHost do
    @behaviour Invocation

    @impl true
    def before_invoke(_invocation, %{before: result}), do: result

    @impl true
    def after_invoke(_receipt, %{after: result}), do: result
  end

  defmodule RaiseHost do
    @behaviour Invocation

    @impl true
    def before_invoke(_invocation, _ref), do: raise("before failed")

    @impl true
    def after_invoke(_receipt, _ref), do: throw(:after_failed)
  end

  describe "public protocol" do
    @describetag contracts: ["INVOKE-001", "INVOKE-002"]

    test "defines exactly the two host callbacks" do
      assert Invocation.behaviour_info(:callbacks) |> Enum.sort() ==
               [after_invoke: 2, before_invoke: 2]

      refute function_exported?(Invocation, :definition, 2)
      refute function_exported?(Invocation, :run, 1)
      refute function_exported?(Invocation, :invoke, 2)
    end

    test "passes the compatibility token through without interpretation" do
      compatibility = {:opaque, self(), make_ref()}
      config = config(compatibility: compatibility)

      assert {:ok, ^config} = Runtime.validate_config(config)

      assert %{compatibility: ^compatibility} =
               Runtime.descriptor(config, occurrence_id(), evidence(), Host, %{value: 1})
    end
  end

  describe "configuration validation" do
    @describetag contracts: ["INVOKE-005"]

    test "rejects missing fields and invalid run keys" do
      valid = config()

      for field <- [:host, :ref, :run_key, :compatibility] do
        assert {:error, %{field: ^field, reason: :missing}} =
                 valid |> Map.delete(field) |> Runtime.validate_config()
      end

      for run_key <- ["", nil, :run_key] do
        assert {:error, %{field: :run_key, reason: :invalid}} =
                 valid |> Map.put(:run_key, run_key) |> Runtime.validate_config()
      end

      assert {:error, %{reason: :invalid_configuration}} = Runtime.validate_config([])

      assert {:error, %{reason: :invalid_configuration}} =
               valid |> Map.put(:storage, :not_supported) |> Runtime.validate_config()
    end

    test "rejects host modules without both callbacks" do
      for host <- [MissingBeforeHost, MissingAfterHost, nil, :not_a_loaded_host] do
        assert {:error, %{field: :host, reason: :invalid}} =
                 config(host: host) |> Runtime.validate_config()
      end
    end

    test "accepts invocation for run options and rejects it for step-wise start" do
      invocation = config()

      assert :ok = Options.validate_action([invocation: invocation], :action)

      assert {:ok, flow_opts} = Options.validate_flow([invocation: invocation], :run)
      assert flow_opts[:invocation] === invocation

      assert {:error, %Jido.Flow.Error.InvalidExecutionError{details: %{option: :invocation}}} =
               Options.validate_flow([invocation: invocation], :start)

      flow =
        Flow.new!(
          name: "invocation_start_rejection",
          components: [Step.new!(name: "one", action: Action, params: %{value: 1})],
          output: %{}
        )

      assert {:error, %Jido.Flow.Error.InvalidExecutionError{details: %{option: :invocation}}} =
               Exec.start(flow, %{}, %{}, invocation: invocation)
    end

    test "keeps existing option defaults when invocation is omitted" do
      assert :ok = Options.validate_action([], :action)
      assert :ok = Options.validate_action([], :instruction)

      assert {:ok, run_opts} = Options.validate_flow([], :run)
      assert run_opts[:max_concurrency] == 8
      assert run_opts[:max_continuations] == 256
      refute Keyword.has_key?(run_opts, :invocation)

      assert {:ok, start_opts} = Options.validate_flow([], :start)
      assert start_opts[:max_concurrency] == 8
      refute Keyword.has_key?(start_opts, :max_continuations)
      refute Keyword.has_key?(start_opts, :invocation)
    end

    test "uses the existing target error type for invalid invocation options" do
      invalid = %{host: Host}

      assert {:error, %Jido.Action.Error.InvalidInputError{details: action_details}} =
               Options.validate_action([invocation: invalid], :action)

      assert action_details.option == :invocation
      assert action_details.field == :ref

      assert {:error, %Jido.Flow.Error.InvalidExecutionError{details: flow_details}} =
               Options.validate_flow([invocation: invalid], :run)

      assert flow_details.option == :invocation
      assert flow_details.field == :ref
    end
  end

  describe "callback validation" do
    @describetag contracts: ["INVOKE-001", "INVOKE-003"]

    test "calls valid host callbacks with the configured reference" do
      config = config(ref: self())
      invocation = invocation(config)
      receipt = Runtime.receipt(invocation, ok_outcome())

      assert {:ok, :execute} = Runtime.before(config, invocation)
      assert_receive {:before_invoke, ^invocation}

      assert :ok = Runtime.after_invoke(config, receipt)
      assert_receive {:after_invoke, ^receipt}
    end

    test "accepts a valid replay and keeps its historical descriptor" do
      current = invocation(config(compatibility: :current))
      historical = %{current | compatibility: :historical, action: MissingAfterHost}
      receipt = Runtime.receipt(historical, ok_outcome())
      config = config(host: ReturnHost, ref: %{before: {:replay, receipt}})

      assert {:ok, {:replay, ^receipt}} = Runtime.before(config, current)
      assert receipt.invocation.compatibility == :historical
    end

    test "turns host interrupt and host error returns into interruption errors" do
      invocation = invocation(config())

      for return <- [{:interrupt, :wait}, {:error, :unavailable}] do
        config = config(host: ReturnHost, ref: %{before: return})

        assert {:error,
                %InterruptedError{
                  details: %{
                    stage: :before_invoke,
                    reason: reason,
                    invocation_id: invocation_id
                  }
                }} = Runtime.before(config, invocation)

        assert reason == elem(return, 1)
        assert invocation_id == invocation.id
      end

      receipt = Runtime.receipt(invocation, ok_outcome())

      for return <- [{:interrupt, :wait}, {:error, :unavailable}] do
        config = config(host: ReturnHost, ref: %{after: return})

        assert {:error,
                %InterruptedError{
                  details: %{stage: :after_invoke, reason: reason, invocation_id: invocation_id}
                }} = Runtime.after_invoke(config, receipt)

        assert reason == elem(return, 1)
        assert invocation_id == invocation.id
      end
    end

    test "turns invalid callback returns and callback failures into interruption errors" do
      invocation = invocation(config())
      receipt = Runtime.receipt(invocation, ok_outcome())

      assert {:error, %InterruptedError{details: %{stage: :before_invoke, reason: reason}}} =
               Runtime.before(config(host: ReturnHost, ref: %{before: :invalid}), invocation)

      assert {:invalid_callback_return, :invalid} = reason

      assert {:error, %InterruptedError{details: %{stage: :after_invoke, reason: reason}}} =
               Runtime.after_invoke(
                 config(host: ReturnHost, ref: %{after: {:replay, receipt}}),
                 receipt
               )

      assert {:invalid_callback_return, {:replay, ^receipt}} = reason

      assert {:error,
              %InterruptedError{details: %{stage: :before_invoke, reason: %RuntimeError{}}}} =
               Runtime.before(config(host: RaiseHost), invocation)

      assert {:error,
              %InterruptedError{
                details: %{stage: :after_invoke, reason: %{kind: :throw, reason: :after_failed}}
              }} = Runtime.after_invoke(config(host: RaiseHost), receipt)
    end
  end

  describe "receipt structure" do
    @describetag contracts: ["INVOKE-002"]

    test "accepts every version 1 occurrence selector and executable evidence shape" do
      occurrence_ids = [
        occurrence_id(),
        %{occurrence_id() | component_path: ["step"], role: :step},
        %{
          occurrence_id()
          | component_path: ["choice"],
            role: :choice,
            selector: %{kind: :option, name: "primary"}
        },
        %{
          occurrence_id()
          | component_path: ["choice"],
            role: :choice,
            selector: %{kind: :fallback}
        },
        %{
          occurrence_id()
          | component_path: ["map"],
            role: :map,
            selector: %{index: 0}
        },
        %{
          occurrence_id()
          | component_path: ["reduce"],
            role: :reduce,
            selector: %{index: 1}
        },
        %{
          occurrence_id()
          | component_path: ["subflow", "iterate"],
            role: :iterate,
            selector: %{index: 2}
        },
        %{
          occurrence_id()
          | component_path: ["dispatch"],
            role: :dispatch,
            selector: %{phase: :decision}
        },
        %{
          occurrence_id()
          | component_path: ["dispatch"],
            role: :dispatch,
            selector: %{phase: :expander}
        }
      ]

      evidences = [
        evidence(),
        %{
          executable: %{kind: :flow, form: :module, module: Host},
          flow_semantic_digest: "semantic",
          compilation_digest: "compiled"
        },
        %{
          executable: %{kind: :flow, form: :value, module: nil},
          flow_semantic_digest: "semantic",
          compilation_digest: "compiled"
        }
      ]

      for id <- occurrence_ids, current_evidence <- evidences do
        current = Runtime.descriptor(config(), id, current_evidence, Host, %{value: 1})
        receipt = Runtime.receipt(current, ok_outcome())
        assert {:ok, ^receipt} = Runtime.validate_receipt(receipt, current)
      end
    end

    test "accepts each normalized outcome shape" do
      current = invocation(config())

      outcomes = [
        ok_outcome(),
        %{kind: :ok, output: Output.raw(42), effects: [:one, :two]},
        %{kind: :error, phase: :input, error: RuntimeError.exception("input")},
        %{kind: :error, phase: :execution, error: ArgumentError.exception("execution")},
        %{kind: :error, phase: :output, error: RuntimeError.exception("output")},
        %{kind: :continue, input: %{value: 1}, target: Host}
      ]

      for outcome <- outcomes do
        receipt = Runtime.receipt(current, outcome)
        assert {:ok, ^receipt} = Runtime.validate_receipt(receipt, current)
      end
    end

    test "rejects unsupported versions and a wrong occurrence key" do
      current = invocation(config())
      receipt = Runtime.receipt(current, ok_outcome())

      assert_replay_error(%{receipt | version: 2}, current, :unsupported_receipt_version)

      historical = put_in(receipt, [:invocation, :version], 2)
      assert_replay_error(historical, current, :unsupported_invocation_version)

      wrong_key = put_in(receipt, [:invocation, :id, :chain_index], 1)
      assert_replay_error(wrong_key, current, :wrong_occurrence_key)

      unsupported_id = put_in(receipt, [:invocation, :id, :version], 2)
      assert_replay_error(unsupported_id, current, :unsupported_identity_version)
    end

    test "rejects malformed successes without running an Action validator" do
      current = invocation(config())

      malformed = [
        %{kind: :ok, output: 42, effects: []},
        %{kind: :ok, output: MapSet.new([1]), effects: []},
        %{
          kind: :ok,
          output: %Output{kind: :batch, value: :not_a_list, meta: %{}},
          effects: []
        },
        %{kind: :ok, output: %{}, effects: [:effect | :improper]}
      ]

      for outcome <- malformed do
        assert_replay_error(Runtime.receipt(current, outcome), current, :invalid_outcome)
      end
    end

    test "rejects malformed failures and continuations" do
      current = invocation(config())

      diagnostic = %{
        type: :execution_failure,
        message: "failed",
        details: %{},
        retryable?: false
      }

      malformed = [
        %{kind: :error, phase: :execution, error: diagnostic},
        %{kind: :error, phase: :other, error: RuntimeError.exception("failed")},
        %{kind: :continue, input: Output.raw(1), target: Host},
        %{kind: :continue, input: 1, target: Host},
        %{kind: :unknown}
      ]

      for outcome <- malformed do
        assert_replay_error(Runtime.receipt(current, outcome), current, :invalid_outcome)
      end
    end

    test "accepts a descriptor with non-map resolved parameters" do
      current = config() |> invocation() |> Map.put(:params, [:resolved, 1])
      receipt = Runtime.receipt(current, ok_outcome())

      assert Runtime.validate_receipt(receipt, current) == {:ok, receipt}
    end

    test "rejects malformed descriptors and selector shapes" do
      current = invocation(config())
      receipt = Runtime.receipt(current, ok_outcome())

      malformed = [
        put_in(receipt, [:invocation, :evidence, :executable, :form], :unknown),
        put_in(receipt, [:invocation, :id, :run_key], ""),
        put_in(receipt, [:invocation, :id, :component_path], [:not_a_string]),
        put_in(receipt, [:invocation, :id, :role], :map),
        put_in(receipt, [:invocation, :id, :role], :choice)
        |> put_in([:invocation, :id, :selector], %{index: 0})
      ]

      for malformed_receipt <- malformed do
        assert_replay_error(malformed_receipt, current, :invalid_invocation)
      end
    end
  end

  describe "interruption error" do
    @describetag contracts: ["INVOKE-003"]

    test "exposes and maps the documented fields" do
      id = occurrence_id()
      error = Exec.Error.interrupted_error(:replay, :invalid_receipt, id)

      assert %InterruptedError{
               message: "Action invocation interrupted",
               details: %{stage: :replay, reason: :invalid_receipt, invocation_id: ^id}
             } = error

      assert Exec.Error.owned?(error)

      assert Exec.Error.to_map(error) == %{
               type: :execution_interrupted,
               message: "Action invocation interrupted",
               details: %{stage: :replay, reason: :invalid_receipt, invocation_id: id},
               retryable?: false
             }
    end

    test "allows a nil invocation id when the occurrence is unknown" do
      assert %InterruptedError{
               details: %{stage: :worker, reason: :missing_result, invocation_id: nil}
             } = Exec.Error.interrupted_error(:worker, :missing_result)
    end
  end

  defp config(overrides \\ []) do
    Map.merge(
      %{host: Host, ref: self(), run_key: "run-1", compatibility: :compatible},
      Map.new(overrides)
    )
  end

  defp invocation(config) do
    Runtime.descriptor(config, occurrence_id(), evidence(), Host, %{value: 1})
  end

  defp occurrence_id do
    %{
      version: 1,
      run_key: "run-1",
      chain_index: 0,
      component_path: [],
      role: :root_action,
      selector: nil
    }
  end

  defp evidence do
    %{
      executable: %{kind: :action, form: :module, module: Host},
      flow_semantic_digest: nil,
      compilation_digest: nil
    }
  end

  defp ok_outcome, do: %{kind: :ok, output: %{value: 1}, effects: []}

  defp assert_replay_error(receipt, current, reason) do
    assert {:error,
            %InterruptedError{
              details: %{stage: :replay, reason: actual, invocation_id: invocation_id}
            }} = Runtime.validate_receipt(receipt, current)

    assert match?({^reason, _details}, actual) or actual == reason
    assert invocation_id == current.id
  end
end
