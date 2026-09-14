Code.require_file("support/throughput.exs", __DIR__)

{opts, args, invalid} =
  OptionParser.parse(System.argv(),
    strict: [profile: :string, output: :string, filter: :string, max_memory_mb: :integer]
  )

if args != [] or invalid != [],
  do:
    raise(
      ArgumentError,
      "usage: mix run test/load/throughput.exs --profile smoke|stress|extreme --filter CASE --output DIRECTORY --max-memory-mb INTEGER"
    )

profile = Keyword.get(opts, :profile, "smoke")
output = Keyword.get(opts, :output, "test/load/results/#{profile}")
File.mkdir_p!(output)
progress = Path.join(output, "progress.jsonl")
File.write!(progress, "")

memory_opts =
  case Keyword.fetch(opts, :max_memory_mb) do
    {:ok, mb} when mb > 0 -> [max_case_process_bytes: mb * 1_048_576]
    :error -> []
    _ -> raise(ArgumentError, "--max-memory-mb must be positive")
  end

on_case = fn row -> File.write!(progress, JSON.encode!(row) <> "\n", [:append]) end

report =
  JidoActionLoad.Throughput.run(
    profile,
    Keyword.get(opts, :filter),
    Keyword.put(memory_opts, :on_case, on_case)
  )

JidoActionLoad.Throughput.write!(report, output)
IO.puts("Wrote #{output}/progress.jsonl, report.json, and report.md")
