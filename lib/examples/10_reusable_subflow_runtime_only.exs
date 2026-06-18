Code.require_file("support.exs", __DIR__)

alias Jido.Exec
alias Jido.Flow
alias Jido.Examples.Support

Support.ensure!()

runtime_flow = Flow.from_workflow(Support.raw_add_workflow())
result = Support.ok!(Exec.run(runtime_flow, %{value: 5}))
%{raw_add: [%{value: 7}]} = Exec.results(result)

to_map_error =
  try do
    Flow.to_map(runtime_flow)
  rescue
    error in ArgumentError -> Exception.message(error)
  end

true = String.contains?(to_map_error, "runtime-only workflow entries")

Support.print("10 reusable subflow runtime-only", %{
  results: Exec.results(result),
  to_map_error: to_map_error
})
