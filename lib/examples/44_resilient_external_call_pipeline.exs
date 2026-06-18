Code.require_file("support.exs", __DIR__)

alias Jido.Exec
alias Jido.Flow
alias Jido.Examples.Actions.AlwaysFail
alias Jido.Examples.Support

Support.ensure!()
Support.quiet_logs!()

fallback = fn _runnable, _error -> {:value, %{service: :fallback, ok: true}} end

flow =
  Flow.new(:resilient_external_call)
  |> Flow.step(:call_service, AlwaysFail)
  |> Flow.policy(:call_service, %{max_retries: 1, backoff: :none, fallback: fallback})

result = Support.ok!(Exec.run(flow, %{}))
%{call_service: [%{service: :fallback, ok: true}]} = Exec.results(result)

Support.print("44 resilient external call pipeline", Exec.results(result))
