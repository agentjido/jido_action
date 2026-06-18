Code.require_file("support.exs", __DIR__)

alias Jido.Exec
alias Jido.Flow
alias Jido.Instruction
alias Jido.Examples.Actions.Add
alias Jido.Examples.Support

Support.ensure!()

instruction = Instruction.new!(action: Add, params: %{amount: 5}, context: %{source: :script})
result = Support.ok!(Exec.run(instruction, %{value: 10}))
%{add: [%{value: 15}]} = Exec.results(result)

Support.print(
  "02 instruction call frame",
  %{
    instruction: instruction,
    results: Exec.results(result),
    graph: Flow.graph(Flow.from_action(instruction))
  }
)
