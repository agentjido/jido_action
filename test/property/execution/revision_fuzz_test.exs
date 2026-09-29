# Use PropCheck's public generator, shrinker, and replay functions directly.
# Do not start its application: that would open and clear the short suite's store.
selected? =
  Enum.any?(ExUnit.configuration()[:include], fn
    :fuzz -> true
    {:fuzz, value} -> value != false
    _ -> false
  end)

if selected? do
  Code.require_file("support/revision_model.exs", __DIR__)

  defmodule JidoActionTest.Property.Execution.RevisionFuzzTest do
    use ExUnit.Case, async: false
    use PropCheck
    import PropCheck.StateM
    alias JidoActionTest.Property.Execution.RevisionModel, as: Model
    @key {__MODULE__, :measurements}

    @tag :fuzz
    @tag max_runs: 500, max_size: 100, max_shrinking_steps: 200, timeout: 900_000
    @tag contracts: ["EXEC-001", "EXEC-002"]
    @tag contract_cases: [
           "EXEC-001/fuzz-competing-claim",
           "EXEC-001/fuzz-failed-terminal",
           "EXEC-002/fuzz-foreign-token",
           "EXEC-002/fuzz-old-token"
         ]
    test "fuzz: command histories preserve revision claims across success and failed states",
         context do
      root = Mix.Project.build_path()
      directory = Path.join(root, "property-counterexamples/revision_histories")
      started = System.monotonic_time(:millisecond)

      Process.put(@key, %{
        phase: :examples,
        outcome: "incomplete",
        generated: 0,
        examples: 0,
        replayed: 0,
        shrink_attempts: 0,
        confirmations: 0,
        observations: %{}
      })

      # PropCheck retains native command terms. Runtime PIDs/tokens are made only
      # when a command executes; they never occur in a generated command input.
      property =
        forall history <- commands(Model, Model.fuzz_state()) do
          check_history(history)
        end

      try do
        for variant <- [false, true, :wave, :complete] do
          assert check_history(fixed_history(variant))
        end

        phase(:replayed)

        for path <- Path.wildcard(Path.join(directory, "*.term")) do
          counterexample = path |> File.read!() |> :erlang.binary_to_term([:safe])
          assert valid_replay?(counterexample), "invalid command replay: #{path}"

          assert PropCheck.check(property, counterexample, [:quiet]) == true,
                 "command replay failed: #{path}"
        end

        phase(:generated)

        result =
          PropCheck.quickcheck(property, [
            :quiet,
            :long_result,
            numtests: context.max_runs,
            max_size: context.max_size,
            max_shrinks: context.max_shrinking_steps
          ])

        case result do
          true ->
            update(&%{&1 | outcome: "passed"})

          counterexample when is_list(counterexample) ->
            File.mkdir_p!(directory)
            encoded = :erlang.term_to_binary(counterexample, [:compressed])
            digest = :crypto.hash(:sha256, encoded) |> Base.encode16(case: :lower)
            path = Path.join(directory, digest <> ".term")
            File.write!(path <> ".tmp", encoded)
            File.rename!(path <> ".tmp", path)
            phase(:confirmations)
            stable? = PropCheck.check(property, counterexample, [:quiet]) == false

            update(
              &Map.merge(&1, %{outcome: "failed", counterexample: path, reproduced: stable?})
            )

            flunk("revision history failed; native replay: #{path}; repeated: #{stable?}")

          other ->
            flunk("PropCheck could not complete revision fuzzing: #{inspect(other)}")
        end
      after
        stats = Process.delete(@key)
        stats = if stats.outcome == "incomplete", do: %{stats | outcome: "failed"}, else: stats
        report_path = Path.join(root, "property-report.json")

        report =
          if File.exists?(report_path),
            do: report_path |> File.read!() |> JSON.decode!(),
            else: %{}

        record =
          Map.merge(Map.drop(stats, [:phase]), %{
            id: "revision_histories",
            variant: "fuzz",
            engine: "PropCheck",
            run_id: report["run_id"],
            contracts: context.contracts,
            declared_forced_cases: context.contract_cases,
            test_timeout: context.timeout,
            elapsed_ms: System.monotonic_time(:millisecond) - started,
            limits: %{
              max_runs: context.max_runs,
              max_size: context.max_size,
              max_shrinking_steps: context.max_shrinking_steps
            },
            revision: report["revision"],
            working_tree_dirty: report["working_tree_dirty"],
            elixir: System.version(),
            otp: System.otp_release()
          })

        path =
          Path.join([
            root,
            "property-fuzz",
            report["run_id"] || "standalone",
            "revision_histories-fuzz.json"
          ])

        File.mkdir_p!(Path.dirname(path))
        File.write!(path <> ".tmp", JSON.encode!(record))
        File.rename!(path <> ".tmp", path)
        Model.cleanup()
      end
    end

    defp check_history(history) do
      field = Process.get(@key).phase
      update(&Map.update!(&1, field, fn count -> count + 1 end))

      try do
        {_events, state, result} = run_commands(Model, history)
        passed = result == :ok

        if passed and field in [:generated, :examples, :replayed] do
          labels =
            [
              if(state.failed, do: "failed-state", else: "nonfailed-state"),
              "commands:#{length(history)}"
            ] ++
              Enum.map(command_names(history), fn {_, name, _} -> "command:#{name}" end)

          update(fn stats ->
            Enum.reduce(Enum.uniq(labels), stats, fn label, acc ->
              update_in(acc.observations, &Map.update(&1, label, 1, fn count -> count + 1 end))
            end)
          end)
        end

        if not passed and field == :generated, do: phase(:shrink_attempts)

        unless passed do
          IO.puts(:stderr, "Revision history rejected: #{inspect(history)}; #{inspect(result)}")
        end

        passed
      after
        Model.cleanup()
      end
    end

    defp fixed_history(operation) when operation in [:wave, :complete] do
      encode_history([
        {:start, [7, 10]},
        {operation, []},
        {:foreign_token, []},
        {:old_token, [0]},
        {:stale, [0, :continue]},
        {:inspect_ready, []}
      ])
    end

    defp fixed_history(failed?) do
      operations =
        if failed? do
          [
            {:start, [6, 2]},
            {:foreign_token, []},
            {:invalid, []},
            {:step, ["node_1"]},
            {:compete, ["node_3"]},
            {:stale, [0, :wave]},
            {:old_token, [0]},
            {:foreign_token, []},
            {:invalid, []},
            {:inspect_ready, []}
          ]
        else
          [
            {:start, [12, -1]},
            {:foreign_token, []},
            {:compete, ["node_10"]},
            {:step, ["node_2"]},
            {:old_token, [0]},
            {:stale, [0, :continue]},
            {:wave, []},
            {:inspect_ready, []}
          ]
        end

      encode_history(operations)
    end

    defp encode_history(operations) do
      [
        {:init, Model.fuzz_state()}
        | Enum.with_index(operations, 1)
          |> Enum.map(fn {{operation, args}, index} ->
            {:set, {:var, index}, {:call, Model, operation, args}}
          end)
      ]
    end

    defp phase(phase), do: update(&%{&1 | phase: phase})
    defp update(fun), do: Process.put(@key, fun.(Process.get(@key)))

    # A local failure file may contain only this model's symbolic calls. Safe
    # binary decoding alone does not prevent a stored call to another module.
    defp valid_replay?([[{:init, initial} | commands]]) do
      initial == Model.fuzz_state() and
        Enum.all?(commands, fn
          {:set, {:var, index}, {:call, Model, operation, args}}
          when is_integer(index) and index > 0 ->
            valid_command?(operation, args)

          _ ->
            false
        end)
    end

    defp valid_replay?(_), do: false

    defp valid_command?(:start, [count, failure]),
      do: is_integer(count) and count in 2..12 and is_integer(failure) and failure in -1..11

    defp valid_command?(operation, [name]) when operation in [:step, :compete],
      do: name in for(index <- 1..12, do: "node_#{index}")

    defp valid_command?(:stale, [index, operation]),
      do: is_integer(index) and index >= 0 and operation in [:step, :wave, :continue]

    defp valid_command?(:old_token, [index]), do: is_integer(index) and index >= 0

    defp valid_command?(operation, []),
      do: operation in [:inspect_ready, :invalid, :foreign_token, :wave, :complete]

    defp valid_command?(_, _), do: false
  end
end
