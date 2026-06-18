Code.require_file("support.exs", __DIR__)

alias Jido.Exec
alias Jido.Exec.Result
alias Jido.Flow
alias Jido.Examples.Actions.Add
alias Jido.Examples.Support

Support.ensure!()

flow = Flow.from_action(Add, %{amount: 2}, name: :add)
result = Support.ok!(Exec.run(flow, %{value: 3}))

cached = Result.new(result.workflow, :ok, results: %{cached: true}, events: [:cached])

%{cached: true} = Exec.results(cached)
%{add: [%{value: 5}]} = Exec.results(cached, refresh: true)

Support.print(
  "18 cached vs live results",
  %{cached: Exec.results(cached), refreshed: Exec.results(cached, refresh: true)}
)
