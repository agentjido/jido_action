Code.require_file("support/suite.exs", __DIR__)

{opts, args, invalid} =
  OptionParser.parse(System.argv(), strict: [profile: :string, output: :string, filter: :string])

if args != [] or invalid != [],
  do:
    raise(
      ArgumentError,
      "usage: mix run bench/run.exs --profile short|scale|smoke|backlog --filter CASE_SUBSTRING --output DIRECTORY"
    )

profile = Keyword.get(opts, :profile, "short")
output = Keyword.get(opts, :output, "bench/results/#{profile}")
report = JidoActionBench.Suite.run(profile, Keyword.get(opts, :filter))
JidoActionBench.Suite.write!(report, output)
IO.puts("Wrote #{output}/report.json and report.md")
