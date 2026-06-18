Code.require_file("support.exs", __DIR__)

alias Jido.Flow
alias Jido.Examples.Functions
alias Jido.Examples.Support

Support.ensure!()

flow = Flow.new(:capture) |> Flow.map(:identity, &Functions.identity/1)
[%{mapper: {Functions, :identity}}] = flow.flow

anonymous_error =
  try do
    Flow.new(:bad) |> Flow.map(:anonymous, fn value -> value end)
  rescue
    error in ArgumentError -> Exception.message(error)
  end

true = String.contains?(anonymous_error, "external function/1 capture")

Support.print("39 external capture normalization", %{
  flow: Flow.to_map(flow),
  anonymous_error: anonymous_error
})
