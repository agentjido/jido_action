Code.require_file("support.exs", __DIR__)

alias Jido.Flow
alias Jido.Examples.Actions.{Add, Double}
alias Jido.Examples.Support

Support.ensure!()

flow =
  Flow.new(:projection_views)
  |> Flow.step(:add, Add, params: %{amount: 1})
  |> Flow.step(:double, Double, after: :add)

%{add: %{action: Add}, double: %{action: Double}} = Flow.node_map(flow)

Support.print(
  "05 projection views",
  %{
    node_map: Flow.node_map(flow),
    graph: Flow.graph(flow),
    components: Map.keys(Flow.components(flow))
  }
)
