defmodule JidoTest.ExecResultTest do
  use JidoTest.ActionCase, async: false

  alias Jido.Exec
  alias Jido.Exec.Result
  alias Jido.Flow
  alias JidoTest.TestActions.Add
  alias Runic.Workflow

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
end
