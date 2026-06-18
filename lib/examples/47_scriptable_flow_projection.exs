Code.require_file("support.exs", __DIR__)

alias Jido.Exec
alias Jido.Flow
alias Jido.Examples.Actions.{Add, Double}
alias Jido.Examples.Support

Support.ensure!()

term_ir = %{
  name: :scriptable,
  flow: [
    %{type: :step, name: :add, action: Add, params: %{amount: 2}},
    %{type: :step, name: :double, action: Double, after: :add}
  ]
}

flow = Flow.new(term_ir)
result = Support.ok!(Exec.run(flow, %{value: 3}))
%{double: [%{value: 10}]} = Exec.results(result)

Support.print("47 Elixir-term flow projection", %{
  ir: Flow.to_map(flow),
  results: Exec.results(result)
})
