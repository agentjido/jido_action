# Manual probe. Run from the package root; never used as a speed pass condition.
Code.require_file("support/fixtures.exs", __DIR__)
Code.require_file("support/measure.exs", __DIR__)
Code.require_file("../load/support/throughput.exs", __DIR__)

defmodule JidoActionBench.EffectDecision do
  use Jido.Action, name: "bench_effect_decision"
  @impl true
  def run(params, context), do: {:ok, params, List.duplicate([params.left], context.batch)}
end

defmodule JidoActionBench.EffectNext do
  use Jido.Action, name: "bench_effect_next"
  @impl true
  def run(%{left: 0}, _), do: {:ok, %{done: true}}
  def run(%{left: left}, context), do: {:continue, %{left: left - 1}, context.flow}
end

defmodule JidoActionBench.EmptyNext do
  use Jido.Action, name: "bench_empty_next"
  @impl true
  def run(%{left: 0}, _), do: {:ok, %{done: true}}
  def run(%{left: left}, _), do: {:continue, %{left: left - 1}, __MODULE__}
end

alias Jido.{Exec, Flow}
alias Jido.Flow.Ref
alias JidoActionBench.{Echo, Measure}
alias Jido.Exec.Flow.{Collection, Frame}

Logger.configure(level: :warning)
[destination | filters] = System.argv()
filter = List.first(filters) || ""

collectors =
  for count <- [128, 2_048, 8_192] do
    tokens =
      for i <- (count - 1)..0//-1,
          do: %{kind: :result, index: i, output: i, effects: [[i]], input: :frame}

    expected =
      Frame.value(:frame, Enum.to_list(0..(count - 1)), for(i <- 0..(count - 1), do: [i]))

    {"collector/#{count}", 100, fn -> Collection.collect_map_tokens(%{name: "map"}, tokens) end,
     expected}
  end

compilers =
  for count <- [1, 32, 128] do
    flow =
      JidoActionTest.FlowBuilder.new!(
        name: "compile",
        components:
          for(i <- 1..count, do: JidoActionTest.FlowComponent.step!(name: "s#{i}", action: Echo)),
        output: %{}
      )

    {:ok, expected} = Flow.semantic_identity(flow)

    {"compile/#{count}", 30,
     fn ->
       {:ok, compiled} = Flow.compile(flow)
       compiled.semantic_digest
     end, expected.digest}
  end

flow =
  JidoActionTest.FlowBuilder.new!(
    name: "effect_chain",
    components: [
      JidoActionTest.FlowComponent.dispatch!(
        name: "next",
        decision: JidoActionBench.EffectDecision,
        expander: JidoActionBench.EffectNext,
        params: Ref.input([])
      )
    ],
    output: Ref.result("next")
  )

chains =
  for {count, batch} <- [{16, 1}, {128, 1}, {128, 64}] do
    expected = {:ok, %{done: true}, Enum.flat_map(count..0//-1, &List.duplicate([&1], batch))}

    {"effects/#{count}/#{batch}", 15,
     fn -> Exec.run(flow, %{left: count}, %{flow: flow, batch: batch}) end, expected}
  end

empty =
  {"empty_chain/128", 200, fn -> Exec.run(JidoActionBench.EmptyNext, %{left: 128}) end,
   {:ok, %{done: true}}}

settings = %{JidoActionLoad.Throughput.settings("smoke") | sizes: [128, 512, 2_048]}

maps =
  settings
  |> JidoActionLoad.Throughput.cases()
  |> Enum.filter(&String.starts_with?(&1.id, "map/jido/unique/"))
  |> Enum.map(fn item ->
    {item.id, 7,
     fn ->
       result = item.run.()
       item.check.(result)
       :ok
     end, :ok}
  end)

actions =
  for timeout <- [:infinity, 30_000] do
    {"action/#{timeout}", 10_000, fn -> Exec.run(Echo, %{value: 42}, %{}, timeout: timeout) end,
     {:ok, %{value: 42}}}
  end

cases =
  for {id, samples, run, expected} <-
        collectors ++ compilers ++ chains ++ [empty] ++ maps ++ actions,
      String.contains?(id, filter) do
    workload = %{
      setup: fn _ -> nil end,
      run: fn _ -> run.() end,
      check: fn actual ->
        if actual != expected, do: raise("wrong result: #{id}")
        :ok
      end
    }

    IO.puts("Measuring #{id}")
    %{id: id, timing: Measure.timing(workload, 3, samples)}
  end

if cases == [], do: raise("no matching cases")

File.write!(
  destination,
  JSON.encode!(%{
    elixir: System.version(),
    otp: System.otp_release(),
    schedulers: :erlang.system_info(:schedulers_online),
    cases: cases
  })
)
