Code.require_file("support.exs", __DIR__)

alias Jido.Exec
alias Jido.Flow
alias Jido.Examples.Functions
alias Jido.Examples.Support

Support.ensure!()

flow =
  Flow.new(:map_primitive)
  |> Flow.map(:double_each, {Functions, :double})

result = Support.ok!(Exec.run(flow, [1, 2, 3]))
[2, 4, 6] = Enum.sort(Exec.results(result, raw: true))

anonymous_error =
  try do
    Flow.new(:bad) |> Flow.map(:anonymous, fn value -> value end)
  rescue
    error in ArgumentError -> Exception.message(error)
  end

true = String.contains?(anonymous_error, "external function/1 capture")

Support.print("11 map primitive MFA", %{
  results: Exec.results(result, raw: true),
  anonymous_error: anonymous_error
})
