# Reuse the isolated consumer and its bounded OS-process runner.
if Mix.env() != :test, do: raise("run this probe with MIX_ENV=test")
alias JidoActionTest.InlineBuild, as: Build
[output] = System.argv()
File.mkdir_p!(output)

temporary =
  Path.join(System.tmp_dir!(), "jido-bench-release-#{System.unique_integer([:positive])}")

File.mkdir_p!(temporary)
previous_target = System.get_env("BENCH_RELEASE_TARGET")

try do
  fixture = Build.setup(%{tmp_dir: temporary})

  File.cp!(
    Path.join(__DIR__, "support/release_fixture.exs"),
    Path.join(fixture.app, "lib/benchmark.ex")
  )

  File.cp!(
    Path.join(__DIR__, "support/release_probe.exs"),
    Path.join(fixture.scripts, "probe.exs")
  )

  {log, status} = Build.mix(fixture, ["release"])
  if status != 0, do: raise(log)
  release = Path.join(fixture.build, "rel/inline_consumer")
  bytes = fn paths -> Enum.sum(Enum.map(paths, &File.stat!(&1).size)) end
  files = Path.wildcard(Path.join(release, "**/*")) |> Enum.filter(&File.regular?/1)

  generated =
    Path.wildcard(Path.join(release, "lib/*/ebin/Elixir.Jido.Action.Generated.Inline.*.beam"))

  File.rm_rf!(fixture.app)
  File.mkdir_p!(fixture.app)

  samples =
    for target <- ["inline", "explicit"], run <- 1..3 do
      System.put_env("BENCH_RELEASE_TARGET", target)
      %{run: run, result: Build.release_probe(fixture)}
    end

  {head, 0} = System.cmd("git", ["rev-parse", "HEAD"])

  report = %{
    commit: String.trim(head),
    elixir: System.version(),
    otp: List.to_string(:erlang.system_info(:otp_release)),
    release_bytes: bytes.(files),
    generated_module_count: length(generated),
    generated_beam_bytes: bytes.(generated),
    samples: samples,
    limits:
      "Same release, fresh VM per sample; two-step inline and explicit flows. ERTS excluded. Boot memory is after application startup, before target use. First-call time excludes VM boot. Source removed before execution."
  }

  File.write!(Path.join(output, "release.json"), JSON.encode!(report))
  IO.puts("Wrote #{output}/release.json")
after
  File.rm_rf!(temporary)

  if previous_target,
    do: System.put_env("BENCH_RELEASE_TARGET", previous_target),
    else: System.delete_env("BENCH_RELEASE_TARGET")
end
