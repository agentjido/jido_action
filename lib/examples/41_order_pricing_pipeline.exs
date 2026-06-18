Code.require_file("support.exs", __DIR__)

alias Jido.Exec
alias Jido.Flow
alias Jido.Examples.Actions.{FormatOrder, NormalizeOrder, PriceOrder, TaxOrder}
alias Jido.Examples.Support

Support.ensure!()

flow =
  Flow.new(:order_pricing)
  |> Flow.step(:normalize, NormalizeOrder)
  |> Flow.step(:price, PriceOrder, after: :normalize)
  |> Flow.step(:tax, TaxOrder, after: :price)
  |> Flow.step(:format, FormatOrder, after: :tax)

input = %{
  order_id: "ord_123",
  items: [%{price_cents: 1_000, quantity: 2}, %{price_cents: 500, quantity: 1}]
}

result = Support.ok!(Exec.run(flow, input))
%{format: [%{summary: "order ord_123: 2706 cents", total_cents: 2706}]} = Exec.results(result)

Support.print("41 order pricing pipeline", Exec.results(result).format)
