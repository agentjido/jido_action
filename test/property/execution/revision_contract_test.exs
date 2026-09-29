# PropCheck checks its counterexample store while expanding property macros.
# Load this suite only when ExUnit explicitly includes the property tag.
selected? =
  Enum.any?(ExUnit.configuration()[:include], fn
    :property -> true
    {:property, value} -> value != false
    _ -> false
  end)

if selected? do
  # PropCheck needs Mix for its counterexample store. Keep it out of the app runtime.
  {:ok, _applications} = Application.ensure_all_started(:propcheck)
  Code.require_file("support/revision_model.exs", __DIR__)

  defmodule JidoActionTest.Property.Execution.RevisionContractTest do
    use ExUnit.Case, async: false

    use PropCheck,
      default_opts: [:quiet, numtests: 80, max_size: 30]

    import PropCheck.StateM
    @moduletag :property
    alias JidoActionTest.Property.Execution.RevisionModel, as: Model

    @tag contracts: ["EXEC-001", "EXEC-002"]
    property "only current revisions with valid tokens can start work" do
      forall commands <- commands(Model) do
        try do
          run = {_history, _state, result} = run_commands(Model, commands)

          aggregate(
            when_fail(result == :ok, print_report(run, commands)),
            command_names(commands)
          )
        after
          Model.cleanup()
        end
      end
    end

    @tag contracts: ["EXEC-001", "EXEC-002"]
    @tag contract_cases: [
           "EXEC-001/old-step",
           "EXEC-001/old-wave",
           "EXEC-001/old-continue",
           "EXEC-002/model-old-token",
           "EXEC-002/model-refresh"
         ]
    test "the model rejects old revisions and tokens across step wave and continue" do
      for operation <- [:wave, :complete] do
        commands = [
          {:set, {:var, 1}, {:call, Model, :start, [3]}},
          {:set, {:var, 2}, {:call, Model, :invalid, []}},
          {:set, {:var, 3}, {:call, Model, :step, ["node_2"]}},
          {:set, {:var, 4}, {:call, Model, :stale, [0, :step]}},
          {:set, {:var, 5}, {:call, Model, :old_token, [0]}},
          {:set, {:var, 6}, {:call, Model, operation, []}},
          {:set, {:var, 7}, {:call, Model, :old_token, [1]}},
          {:set, {:var, 8}, {:call, Model, :stale, [0, :wave]}},
          {:set, {:var, 9}, {:call, Model, :stale, [1, :continue]}},
          {:set, {:var, 10}, {:call, Model, :inspect_ready, []}}
        ]

        try do
          assert {_history, _state, :ok} = run_commands(Model, commands)
        after
          Model.cleanup()
        end
      end
    end
  end
end
