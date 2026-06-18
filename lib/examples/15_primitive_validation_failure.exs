Code.require_file("support.exs", __DIR__)

alias Jido.Flow
alias Jido.Examples.Functions
alias Jido.Examples.Support

Support.ensure!()

invalid_callable =
  try do
    Flow.new(:bad) |> Flow.map(:missing, {Functions, :missing})
  rescue
    error in ArgumentError -> Exception.message(error)
  end

duplicate_name =
  try do
    Flow.new(:bad)
    |> Flow.map(:same, {Functions, :identity})
    |> Flow.map(:same, {Functions, :double})
  rescue
    error in ArgumentError -> Exception.message(error)
  end

bad_reduce_map =
  try do
    Flow.new(:bad)
    |> Flow.reduce(:sum, 0, {Functions, :sum}, map: :missing)
    |> Flow.to_workflow()
  rescue
    error in ArgumentError -> Exception.message(error)
  end

true = String.contains?(invalid_callable, "existing function/1")
true = String.contains?(duplicate_name, "already contains")
true = String.contains?(bad_reduce_map, "unknown map")

Support.print("15 primitive validation failure", %{
  invalid_callable: invalid_callable,
  duplicate_name: duplicate_name,
  bad_reduce_map: bad_reduce_map
})
