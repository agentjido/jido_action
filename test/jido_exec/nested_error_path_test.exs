defmodule JidoActionTest.Exec.NestedErrorPathTest do
  use ExUnit.Case, async: true

  alias Jido.{Exec, Flow}
  alias Jido.Flow.{Ref, Subflow}

  defmodule Write do
    use Jido.Action,
      name: "path_write",
      schema: Zoi.object(%{mode: Zoi.string()}),
      output_schema: Zoi.object(%{value: Zoi.integer()})

    @impl true
    def run(%{mode: "output"}, _), do: {:ok, %{value: "bad"}}
    def run(%{mode: "ok"}, _), do: {:ok, %{value: 1}}

    def run(params, context) do
      if context[:owner] do
        send(context.owner, {:ready, self()})
        receive do: (:release -> :ok)
      end

      {:error,
       Jido.Action.Error.execution_error("write failed", %{code: params.mode, retry: true})}
    end
  end

  defmodule Child do
    use Jido.Flow, name: "path_child"

    flow do
      step "write/file", action: Write, params: %{mode: input(:mode)}
      output result("write/file")
    end
  end

  defmodule Middle do
    use Jido.Flow, name: "path_middle"

    flow do
      step "review", action: Child, params: %{mode: input(:mode)}
      output result("review")
    end
  end

  defmodule Boundary do
    use Jido.Flow,
      name: "path_boundary",
      schema: Zoi.object(%{mode: Zoi.string()}),
      output_schema: Zoi.object(%{missing: Zoi.string()})

    flow do
      step "write", action: Write, params: %{mode: input(:mode)}
      output result("write")
    end
  end

  defmodule Mapped do
    use Jido.Flow, name: "path_map"

    flow do
      map "work", collection: [1], action: Write, params: %{mode: input(:mode)}
      output %{values: result("work")}
    end
  end

  defmodule Reduced do
    use Jido.Flow, name: "path_reduce"

    flow do
      reduce "work", collection: [1], initial: %{}, action: Write, params: %{mode: input(:mode)}
      output result("work")
    end
  end

  defmodule Iterated do
    use Jido.Flow, name: "path_iterate"

    flow do
      iterate "work" do
        state [], initial: %{}
        action Write
        params %{mode: input(:mode)}
        update %{}
        repeat 1
      end

      output result("work")
    end
  end

  defmodule Chosen do
    use Jido.Flow, name: "path_choice"

    flow do
      choice "work" do
        option "yes",
          condition: input(:mode) == "failure",
          action: Write,
          params: %{mode: input(:mode)}

        otherwise action: Write, params: %{mode: input(:mode)}
      end

      output result("work")
    end
  end

  test "nested Flow validation identifies the boundary in both modes" do
    for {mode, phase} <- [{42, :subflow_input}, {"ok", :subflow_output}],
        run <- [&Exec.run/2, &step_run/2] do
      assert {:error, error} = run.(parent(Boundary, ["review"]), %{mode: mode})
      assert error.details.node_path == ["review"]
      assert error.details.phase == phase
      assert error.details.component == "review"
    end
  end

  test "nested collection and Choice Action failures include the authored path" do
    for child <- [Mapped, Reduced, Iterated, Chosen], run <- [&Exec.run/2, &step_run/2] do
      assert {:error, error} = run.(parent(child, ["review"]), %{mode: "failure"})
      assert error.details.node_path == ["review", "work"]
      assert error.details.node == "work"
      assert %Jido.Action.Error.ExecutionFailureError{} = error
    end
  end

  test "nested Action errors keep type, phase, details, and authored path in both modes" do
    for mode <- ["failure", "output", 42], run <- [&Exec.run/2, &step_run/2] do
      assert {:error, error} = run.(parent(Middle, ["publish/draft"]), %{mode: mode})
      assert error.details.node_path == ["publish/draft", "review", "write/file"]
      assert error.details.node == "write/file"
      assert error.details.action == Write

      case mode do
        "failure" ->
          assert %Jido.Action.Error.ExecutionFailureError{} = error
          assert error.details.phase == :step_execution
          assert error.details.code == "failure"
          assert Jido.Action.Error.retryable?(error)

        "output" ->
          assert error.details.phase == :step_output

        42 ->
          assert error.details.phase == :step_input
      end
    end
  end

  test "concurrent failures distinguish two uses of the same child" do
    owner = self()

    task =
      Task.async(fn ->
        Exec.run(parent(Child, ["draft", "review"]), %{mode: "failure"}, %{owner: owner},
          max_concurrency: 2
        )
      end)

    try do
      assert_receive {:ready, first}, 1_000
      assert_receive {:ready, second}, 1_000
      send(second, :release)
      send(first, :release)
      assert {:error, error} = Task.await(task)
      mapped = Jido.Flow.Error.to_map(error)
      assert mapped.type == :flow_execution_error

      assert Enum.map(mapped.details.failures, & &1.error.details.node_path) == [
               ["draft", "write/file"],
               ["review", "write/file"]
             ]
    after
      Task.shutdown(task, :brutal_kill)
    end
  end

  defp parent(child, names) do
    Flow.new!(
      name: "path_root",
      components:
        Enum.map(names, fn name ->
          Subflow.new!(name: name, flow: child, params: %{mode: Ref.input(:mode)})
        end),
      output: %{value: Ref.result(List.last(names))}
    )
  end

  defp step_run(flow, input) do
    {:ok, execution} = Exec.start(flow, input)
    finish(execution)
  end

  defp finish(execution) do
    if Exec.status(execution) == :running do
      {:ok, _, next} = Exec.step(execution)
      finish(next)
    else
      Exec.result(execution)
    end
  end
end
