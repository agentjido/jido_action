Code.require_file("support.exs", __DIR__)

alias Jido.Flow
alias Jido.Examples.Actions.Add
alias Jido.Examples.Support

Support.ensure!()

flow = Flow.from_action(Add, %{amount: 2}, name: :add)
json = flow |> Flow.to_map() |> Jason.encode!()

true = String.contains?(json, "Elixir.Jido.Examples.Actions.Add")

Support.print("36 JSON-safe-ish IR", %{json: json})
