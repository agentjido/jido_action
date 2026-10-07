defmodule JidoActionBench.Increment do
  use Jido.Action, name: "benchmark_increment"

  @impl true
  def run(%{value: value}, _context), do: {:ok, %{value: value + 1}}
end

defmodule JidoActionBench.Serial do
  use Jido.Flow, name: "benchmark_serial"

  flow do
    step "first",
      action: JidoActionBench.Increment,
      params: %{value: input(:value)}

    step "second",
      action: JidoActionBench.Increment,
      params: %{value: result("first", :value)}

    output result("second")
  end
end

{opts, args, invalid} =
  OptionParser.parse(System.argv(), strict: [samples: :integer, warmup: :integer])

if args != [] or invalid != [] do
  raise ArgumentError, "usage: mix run test/bench/run.exs [--samples N] [--warmup N]"
end

samples = Keyword.get(opts, :samples, 100)
warmup = Keyword.get(opts, :warmup, 20)

if samples < 1 or warmup < 0 do
  raise ArgumentError, "samples must be positive and warmup must be non-negative"
end

cases = [
  {"action/run", fn -> Jido.Exec.run(JidoActionBench.Increment, %{value: 1}) end,
   {:ok, %{value: 2}}},
  {"flow/compile", fn -> Jido.Exec.compile(JidoActionBench.Serial) end, :workflow},
  {"flow/run", fn -> Jido.Exec.run(JidoActionBench.Serial, %{value: 1}) end, {:ok, %{value: 3}}}
]

measure = fn fun ->
  started = System.monotonic_time()
  result = fun.()
  elapsed = System.monotonic_time() - started
  {System.convert_time_unit(elapsed, :native, :microsecond), result}
end

Enum.each(cases, fn {name, fun, expected} ->
  if warmup > 0, do: Enum.each(1..warmup, fn _ -> fun.() end)

  values =
    Enum.map(1..samples, fn _ ->
      {elapsed, result} = measure.(fun)

      case expected do
        :workflow ->
          unless match?({:ok, %Runic.Workflow{}}, result), do: raise("incorrect #{name} result")

        ^result ->
          :ok

        _ ->
          raise "incorrect #{name} result: #{inspect(result)}"
      end

      elapsed
    end)
    |> Enum.sort()

  median = Enum.at(values, div(length(values), 2))
  p95 = Enum.at(values, min(length(values) - 1, floor(length(values) * 0.95)))
  IO.puts("#{name}: median=#{median}us p95=#{p95}us samples=#{samples}")
end)
