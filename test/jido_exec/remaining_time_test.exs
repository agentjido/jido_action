defmodule JidoActionTest.Exec.RemainingTimeTest do
  use ExUnit.Case, async: true
  alias Jido.Exec
  alias Jido.Flow
  alias Jido.Flow.{Ref, Step, Subflow}
  alias Jido.Instruction

  defmodule ReadBudget do
    use Jido.Action, name: "read_remaining_budget"
    @impl true
    def run(params, context),
      do: {:ok, %{remaining: Exec.remaining_time(context), context: context, params: params}}
  end

  defmodule Operation do
    use Jido.Action, name: "remaining_budget_operation"
    @impl true
    def run(%{work: work}, context), do: work.(context)
  end

  defmodule ChildFlow do
    use Jido.Flow, name: "budget_child"

    flow do
      step "read", action: ReadBudget, params: %{}
      output result("read")
    end
  end

  setup do
    %{opts: [task_supervisor: start_supervised!(Task.Supervisor)]}
  end

  test "missing metadata is distinct from unlimited execution", %{opts: opts} do
    assert Exec.remaining_time(%{}) == nil
    assert {:ok, %{remaining: nil}} = ReadBudget.run(%{}, %{})

    assert {:ok, %{remaining: :infinity, context: %{__jido_exec__: %{deadline: :infinity}}}} =
             Exec.run(ReadBudget, %{}, %{}, opts)

    refute function_exported?(Exec, :remaining_time, 0)
  end

  test "timed work adds only the reserved field", %{opts: opts} do
    context = %{tenant: "one", deadline: :business_value}
    dictionary = Process.get()

    assert {:ok, %{remaining: remaining, context: actual}} =
             Exec.run(ReadBudget, %{}, context, opts ++ [timeout: 30_000])

    assert is_integer(remaining) and remaining >= 0 and remaining <= 30_000
    assert Map.delete(actual, :__jido_exec__) == context
    assert is_integer(actual.__jido_exec__.deadline)
    assert Process.get() == dictionary
  end

  test "expiry clamps to zero and large budgets are not capped" do
    assert Exec.remaining_time(%{
             __jido_exec__: %{deadline: System.monotonic_time(:millisecond) - 1}
           }) == 0

    assert Exec.remaining_time(%{
             __jido_exec__: %{deadline: System.monotonic_time(:millisecond) + 1_099_511_627_776}
           }) > 2_147_483_647
  end

  for mode <- [:sync, :async], timeout <- [:infinity, 60_000, 10_000] do
    @tag mode: mode, inner_timeout: timeout
    test "#{mode} nested timeout #{timeout} uses explicit context", %{
      opts: opts,
      mode: mode,
      inner_timeout: timeout
    } do
      work = fn context ->
        result = run(mode, ReadBudget, %{}, context, opts ++ [timeout: timeout])
        {:ok, %{parent: context, result: result}}
      end

      assert {:ok, %{parent: parent, result: {:ok, child}}} =
               Exec.run(Operation, %{work: work}, %{}, opts ++ [timeout: 30_000])

      if timeout == 10_000,
        do: assert(child.context.__jido_exec__.deadline < parent.__jido_exec__.deadline),
        else: assert(child.context.__jido_exec__.deadline == parent.__jido_exec__.deadline)
    end
  end

  test "nested calls without context do not inherit hidden state", %{opts: opts} do
    work = fn _context -> Exec.run(ReadBudget, %{}, %{}, opts) end

    assert {:ok, %{remaining: :infinity}} =
             Exec.run(Operation, %{work: work}, %{}, opts ++ [timeout: 30_000])
  end

  test "Tasks can read explicitly passed context", %{opts: opts} do
    work = fn context ->
      task =
        Task.async(fn ->
          %{remaining: Exec.remaining_time(context), missing: Exec.remaining_time(%{})}
        end)

      {:ok, Task.await(task)}
    end

    assert {:ok, %{remaining: remaining, missing: nil}} =
             Exec.run(Operation, %{work: work}, %{}, opts ++ [timeout: 30_000])

    assert is_integer(remaining)
  end

  test "continuations retain the exact deadline", %{opts: opts} do
    work = fn context -> {:continue, %{deadline: context.__jido_exec__.deadline}, ReadBudget} end

    assert {:ok,
            %{params: %{deadline: deadline}, context: %{__jido_exec__: %{deadline: deadline}}}} =
             Exec.run(Operation, %{work: work}, %{}, opts ++ [timeout: 30_000])

    assert is_integer(deadline)
  end

  for mode <- [:sync, :async] do
    @tag mode: mode
    test "#{mode} Instruction context is merged before injection", %{opts: opts, mode: mode} do
      deadline = System.monotonic_time(:millisecond) + 30_000

      instruction =
        Instruction.new!(
          target: ReadBudget,
          context: %{tenant: "old", keep: true, __jido_exec__: %{deadline: deadline}}
        )

      assert {:ok,
              %{context: %{tenant: "new", keep: true, __jido_exec__: %{deadline: ^deadline}}}} =
               run(mode, instruction, %{}, [tenant: "new"], opts)
    end
  end

  test "parallel work, Subflows, and Map items share the deadline", %{opts: opts} do
    flow =
      Flow.new!(
        name: "parallel_budget",
        components: [
          Step.new!(name: "read", action: ReadBudget, params: %{}),
          Subflow.new!(name: "child", flow: ChildFlow, params: %{}),
          Jido.Flow.Map.new!(
            name: "items",
            collection: [1, 2],
            action: ReadBudget,
            params: %{id: Ref.item()}
          )
        ],
        output: %{
          read: Ref.result("read"),
          child: Ref.result("child"),
          items: Ref.result("items")
        }
      )

    assert {:ok, %{read: read, child: child, items: items}} =
             Exec.run(flow, %{}, %{}, opts ++ [timeout: 30_000, max_concurrency: 4])

    assert [deadline] =
             Enum.uniq(Enum.map([read, child | items], & &1.context.__jido_exec__.deadline))

    assert is_integer(deadline)
  end

  for mode <- [:step, :selected_step, :wave, :continue] do
    test "#{mode} preserves explicit step-wise context", %{opts: opts} do
      for context <- [%{}, %{__jido_exec__: %{deadline: System.monotonic_time(:millisecond) - 1}}] do
        assert {:ok, execution} = Exec.start(ChildFlow, %{}, context, opts)

        assert {:ok, %{remaining: remaining}} =
                 execution |> finish(unquote(mode)) |> Exec.result()

        assert remaining == if(context == %{}, do: :infinity, else: 0)
      end
    end
  end

  test "malformed reserved metadata is rejected before work", %{opts: opts} do
    owner = self()
    ref = make_ref()

    work = fn _context ->
      send(owner, ref)
      {:ok, %{}}
    end

    for metadata <- [nil, "collision", %{}, %{deadline: "invalid"}] do
      assert {:error, %Jido.Action.Error.InvalidInputError{}} =
               Exec.run(Operation, %{work: work}, %{__jido_exec__: metadata}, opts)
    end

    refute_received ^ref
  end

  test "zero timeout starts no callback", %{opts: opts} do
    owner = self()
    ref = make_ref()

    work = fn _context ->
      send(owner, ref)
      {:ok, %{}}
    end

    assert {:error, %Jido.Action.Error.TimeoutError{}} =
             Exec.run(Operation, %{work: work}, %{}, opts ++ [timeout: 0])

    refute_received ^ref
  end

  defp run(:sync, target, params, context, opts), do: Exec.run(target, params, context, opts)

  defp run(:async, target, params, context, opts),
    do: Exec.await(Exec.run_async(target, params, context, opts))

  defp finish(execution, mode) do
    if Exec.status(execution) == :running do
      next =
        case mode do
          :step ->
            {:ok, _, next} = Exec.step(execution)
            next

          :selected_step ->
            [work | _] = Exec.ready(execution)
            {:ok, _, next} = Exec.step(execution, work.token)
            next

          :wave ->
            {:ok, _, next} = Exec.wave(execution)
            next

          :continue ->
            {:ok, next} = Exec.continue(execution)
            next
        end

      finish(next, mode)
    else
      execution
    end
  end
end
