defmodule Jido.Exec.RuntimeErrorBoundaryTest do
  use ExUnit.Case, async: false
  @moduletag capture_log: true

  alias Jido.Action.Error
  alias Jido.Exec
  alias Jido.Flow.Ref
  alias Runic.Runner
  alias Runic.Workflow
  alias Runic.Workflow.RunnableFailed

  defmodule Echo do
    use Jido.Action, name: "runtime_boundary_echo"
    @impl true
    def run(params, _), do: {:ok, params}
  end

  defmodule LargeOutput do
    use Jido.Action, name: "runtime_boundary_large_output"
    @impl true
    def run(_, _), do: {:ok, %{data: :binary.copy("x", 17 * 1024 * 1024)}, [:discarded]}
  end

  defmodule ForeignError do
    use Splode.Error, class: :execution, fields: [message: "foreign"]
  end

  defmodule :runtime_boundary_error do
    defexception message: "foreign atom module"
  end

  defmodule ExplicitError do
    use Jido.Action, name: "runtime_boundary_explicit_error"
    @impl true
    def run(%{error: error}, _), do: {:error, error}
  end

  defmodule ManyItems do
    use Jido.Action, name: "runtime_boundary_many_items"
    @impl true
    def run(_, _), do: {:ok, %{items: Enum.to_list(1..60_000)}, [:discarded]}
  end

  setup do
    runner = :"runtime_boundary_runner_#{System.unique_integer([:positive])}"
    start_supervised!({Runner, name: runner})
    %{runner: runner}
  end

  test "oversized managed input returns an error before creating a Worker", %{runner: runner} do
    flow =
      Jido.Flow.new!(%{
        name: "runtime_boundary_input",
        components: [
          %{kind: :step, name: "echo", action: Echo, params: %{data: Ref.input(:data)}}
        ],
        output: Ref.result("echo")
      })

    for {id, data} <- [
          bytes: :binary.copy("x", 17 * 1024 * 1024),
          items: Enum.to_list(1..100_001)
        ] do
      assert {:error,
              %Error.ExecutionFailureError{
                details: %{phase: :durability, reason: %Runic.Identity.CanonicalError{}}
              }} =
               Exec.start(runner, id, flow, %{data: data})

      assert Runner.lookup(runner, id) == nil
      owner = self()

      assert {:ok, _} =
               Exec.start(runner, id, flow, %{data: "ok"}, %{},
                 on_complete: fn _, wf -> send(owner, {:done, id, wf}) end
               )

      assert_receive {:done, ^id, workflow}, 2000
      assert Exec.result(workflow) == {:ok, %{data: "ok"}}
    end
  end

  test "native output encoding errors return Jido errors without effects" do
    assert {:error,
            %Error.ExecutionFailureError{details: %{reason: %Runic.Identity.CanonicalError{}}}} =
             Exec.run(LargeOutput)
  end

  test "projection preserves explicit exception failures" do
    known = [
      Error.execution_error("known", %{retry: true}),
      Jido.Flow.Error.execution_error("flow", %{phase: :coordination})
    ]

    for error <- known do
      assert Exec.result(failed_workflow(error)) == {:error, error}
    end

    for error <- [RuntimeError.exception("external"), ForeignError.exception(message: "external")] do
      assert Exec.result(failed_workflow(error)) == {:error, error}
    end
  end

  test "automatic stopped admission reports its drained state", %{runner: runner} do
    owner = self()

    assert {:ok, _} =
             Exec.start(runner, :stopped, LargeOutput, %{}, %{},
               on_complete: fn _, wf -> send(owner, {:stopped, wf}) end
             )

    assert_receive {:stopped, completed}, 2000
    assert {:complete, workflow} = Exec.step(runner, :stopped)
    assert workflow == completed
    assert {:ok, %{status: :stopped, active_units: 0}} = Runner.admission_status(runner, :stopped)
  end

  test "oversized Flow output is a known encoding failure", %{runner: runner} do
    flow =
      Jido.Flow.new!(%{
        name: "runtime_boundary_context_output",
        components: [
          %{kind: :step, name: "echo", action: Echo, params: %{}}
        ],
        output: %{data: Ref.context(:data)}
      })

    owner = self()

    assert {:ok, _} =
             Exec.start(
               runner,
               :context_output,
               flow,
               %{},
               %{data: :binary.copy("x", 17 * 1024 * 1024)},
               on_complete: fn _, wf -> send(owner, {:output_done, wf}) end
             )

    assert_receive {:output_done, workflow}, 2000

    assert {:error,
            %Error.ExecutionFailureError{details: %{reason: %Runic.Identity.CanonicalError{}}}} =
             Exec.result(workflow)

    assert Enum.any?(workflow.runnable_events, &is_struct(&1, RunnableFailed))
    refute Enum.any?(workflow.runnable_events, &is_struct(&1, Runic.Workflow.ExecutionUncertain))
  end

  test "explicit callback exceptions retain their type and value" do
    for error <- [
          ArgumentError.exception("caller"),
          :runtime_boundary_error.exception([]),
          Runic.Identity.CanonicalError.exception(reason: :caller)
        ] do
      assert Exec.run(ExplicitError, %{error: error}) == {:error, error}
      assert Exec.result(failed_workflow(error)) == {:error, error}
    end
  end

  for mode <- [:immediate, :managed] do
    test "#{mode} aggregate size rejection is a known failure", %{runner: runner} do
      flow =
        Jido.Flow.new!(%{
          name: "runtime_boundary_aggregate",
          components: [
            %{kind: :step, name: "a", action: ManyItems},
            %{kind: :step, name: "b", action: ManyItems}
          ],
          output: %{a: Ref.result("a"), b: Ref.result("b")}
        })

      case unquote(mode) do
        :immediate ->
          assert {:error,
                  %Error.ExecutionFailureError{
                    details: %{reason: %Runic.Identity.CanonicalError{}}
                  }} = Exec.run(flow)

        :managed ->
          owner = self()

          assert {:ok, worker} =
                   Exec.start(runner, :aggregate_size, flow, %{}, %{},
                     on_complete: fn _, wf -> send(owner, {:aggregate_done, wf}) end
                   )

          assert_receive {:aggregate_done, workflow}, 5000
          assert Process.alive?(worker)
          assert Runner.lookup(runner, :aggregate_size) == worker

          assert {:error,
                  %Error.ExecutionFailureError{
                    details: %{reason: %Runic.Identity.CanonicalError{}}
                  }} = Exec.result(workflow)

          assert {:ok, %{status: :stopped, active_units: 0}} =
                   Runner.admission_status(runner, :aggregate_size)

          failures = Enum.filter(workflow.runnable_events, &is_struct(&1, RunnableFailed))
          assert failures != []

          for failure <- failures do
            refute Enum.any?(workflow.runnable_events, fn event ->
                     is_struct(event, Runic.Workflow.RunnableCompleted) and
                       event.runnable_id == failure.runnable_id
                   end)
          end

          refute Enum.any?(
                   workflow.runnable_events,
                   &is_struct(&1, Runic.Workflow.ExecutionUncertain)
                 )
      end
    end
  end

  defp failed_workflow(error) do
    Workflow.new()
    |> Map.put(:runnable_events, [%RunnableFailed{runnable_id: :probe, error: error}])
  end
end
