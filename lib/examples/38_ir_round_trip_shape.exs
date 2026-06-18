Code.require_file("support.exs", __DIR__)

alias Jido.Exec
alias Jido.Flow
alias Jido.Examples.Actions.Add
alias Jido.Examples.Support

Support.ensure!()

attrs = %{
  name: :round_trip,
  flow: [
    %{type: :step, name: :add, action: Add, params: %{amount: 4}}
  ]
}

flow = Flow.new(attrs)

%{name: :round_trip, flow: [%{type: :step, name: :add, params: %{amount: 4}}]} =
  Flow.to_map(flow)

result = Support.ok!(Exec.run(flow, %{value: 1}))
%{add: [%{value: 5}]} = Exec.results(result)

Support.print("38 Elixir-term IR round-trip shape", %{
  ir: Flow.to_map(flow),
  results: Exec.results(result)
})
