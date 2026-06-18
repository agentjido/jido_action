Code.require_file("support.exs", __DIR__)

alias Jido.Exec
alias Jido.Flow
alias Jido.Examples.Actions.{Add, Double}
alias Jido.Examples.Support
alias Runic.Workflow

Support.ensure!()

parent = self()

flow =
  Flow.new(:checkpoint_observer)
  |> Flow.step(:add, Add, params: %{amount: 1})
  |> Flow.step(:double, Double, after: :add)

result =
  Support.ok!(
    Exec.run(flow, %{value: 2},
      checkpoint: fn workflow ->
        send(parent, {:checkpoint, Workflow.raw_productions(workflow)})
      end
    )
  )

%{double: [%{value: 6}]} = Exec.results(result)

checkpoints =
  for _ <- 1..2 do
    receive do
      {:checkpoint, productions} -> productions
    after
      100 -> raise "missing checkpoint"
    end
  end

Support.print("20 checkpoint observer", checkpoints)
