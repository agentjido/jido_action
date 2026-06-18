Code.require_file("support.exs", __DIR__)

alias Jido.Exec
alias Jido.Flow
alias Jido.Examples.Actions.ContextEcho
alias Jido.Examples.Support

Support.ensure!()

flow =
  Flow.new(:branch_context)
  |> Flow.step(:left, ContextEcho, context: %{static: :left})
  |> Flow.step(:right, ContextEcho, context: %{static: :right})

result =
  Support.ok!(Exec.run(flow, %{value: 7}, run_context: %{runtime: true, tenant: "acme"}))

%{
  left: [%{static: :left, runtime: true, tenant: "acme"}],
  right: [%{static: :right, runtime: true, tenant: "acme"}]
} = Exec.results(result)

Support.print("09 branch-local context", Exec.results(result))
