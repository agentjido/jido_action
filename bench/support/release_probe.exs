{:ok, _} = Application.ensure_all_started(:inline_consumer)

target =
  case System.fetch_env!("BENCH_RELEASE_TARGET") do
    "inline" -> InlineConsumer.Steps
    "explicit" -> JidoActionBench.ReleaseFlow
  end

boot = %{memory: Map.new(:erlang.memory()), loaded_modules: length(:code.all_loaded())}

measure = fn ->
  before = System.monotonic_time()
  result = Jido.Exec.run(target, %{value: 2})
  elapsed = System.monotonic_time() - before
  {:ok, %{value: 6}} = result
  System.convert_time_unit(elapsed, :native, :nanosecond)
end

first = measure.()
warm = for _ <- 1..100, do: measure.()

IO.puts(
  "INLINE_RESULT=" <>
    JSON.encode!(%{
      target: target,
      boot: boot,
      first_ns: first,
      warm_ns: warm,
      after_memory: Map.new(:erlang.memory()),
      loaded_modules: length(:code.all_loaded())
    })
)
