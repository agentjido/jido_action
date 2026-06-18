Code.require_file("support.exs", __DIR__)

alias Jido.Flow
alias Jido.Examples.Actions.AlwaysFail
alias Jido.Examples.Support

Support.ensure!()

flow =
  Flow.from_action(AlwaysFail, %{}, name: :unstable)
  |> Flow.policy(:unstable, %{fallback: fn _runnable, _error -> {:value, %{ok: true}} end})

json_error =
  try do
    flow |> Flow.to_map() |> Jason.encode!()
  rescue
    error in Protocol.UndefinedError -> Exception.message(error)
  end

true = String.contains?(json_error, "Jason.Encoder")

Support.print("37 non JSON-safe IR", %{json_error: json_error})
