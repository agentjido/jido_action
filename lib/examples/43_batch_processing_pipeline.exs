Code.require_file("support.exs", __DIR__)

alias Jido.Exec
alias Jido.Flow
alias Jido.Examples.Functions
alias Jido.Examples.Support

Support.ensure!()

flow =
  Flow.new(:batch_processing)
  |> Flow.map(:line_totals, {Functions, :item_total})
  |> Flow.reduce(:subtotal, 0, {Functions, :sum}, after: :line_totals, map: :line_totals)
  |> Flow.reduce(:count, 0, {Functions, :count})

items = [%{price_cents: 1_000, quantity: 2}, %{price_cents: 500, quantity: 1}]
result = Support.ok!(Exec.run(flow, items))

true = 2500 in Exec.results(result, raw: true)
true = 2 in Exec.results(result, raw: true)

Support.print("43 batch processing pipeline", Exec.results(result))
