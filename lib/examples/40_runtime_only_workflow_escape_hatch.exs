Code.require_file("support.exs", __DIR__)

alias Jido.Exec
alias Jido.Flow
alias Jido.Examples.Support

Support.ensure!()

flow = Flow.from_workflow(Support.raw_add_workflow())
result = Support.ok!(Exec.run(flow, %{value: 8}))
%{raw_add: [%{value: 10}]} = Exec.results(result)

to_map_error =
  try do
    Flow.to_map(flow)
  rescue
    error in ArgumentError -> Exception.message(error)
  end

true = String.contains?(to_map_error, "runtime-only workflow entries")

Support.print("40 runtime-only workflow escape hatch", %{
  results: Exec.results(result),
  to_map_error: to_map_error
})
