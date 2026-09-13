# Prebuild with MIX_ENV=test mix compile --warnings-as-errors, then run:
# MIX_ENV=test mix run --no-compile test/bench/dsl_compile_probe.exs OUTPUT [SAMPLES]
if Mix.env() != :test, do: raise("run this probe with MIX_ENV=test")

defmodule JidoActionBench.DSLCompileProbe do
  @moduledoc false
  alias JidoActionTest.InlineBuild, as: Build

  @ordinary """
  defmodule InlineConsumer.Echo do
    use Jido.Action, name: "compile_probe_echo"
    @impl true
    def run(params, _context), do: {:ok, params}
  end

  defmodule InlineConsumer.Keyword do
    use Jido.Flow, name: "compile_probe_map"
    flow do
      map "mapped",
        collection: input(:items),
        action: InlineConsumer.Echo,
        params: %{value: item(:value) + input(:offset)}
      output %{values: result("mapped")}
    end
  end

  defmodule InlineConsumer.Block do
    use Jido.Flow, name: "compile_probe_map"
    flow do
      map "mapped" do
        collection input(:items)
        action InlineConsumer.Echo
        params %{value: item(:value) + input(:offset)}
      end
      output %{values: result("mapped")}
    end
  end
  """

  @ordinary_check """
  {:ok, _} = Application.ensure_all_started(:inline_consumer)
  left = InlineConsumer.Keyword.flow()
  right = InlineConsumer.Block.flow()
  true = Jido.Flow.to_map(left) == Jido.Flow.to_map(right)
  {:ok, identity} = Jido.Flow.semantic_identity(left)
  {:ok, ^identity} = Jido.Flow.semantic_identity(right)
  offset = System.fetch_env!("INLINE_OFFSET") |> String.to_integer()
  expected = %{values: [%{value: 2 + offset}, %{value: 4 + offset}]}
  for owner <- [InlineConsumer.Keyword, InlineConsumer.Block] do
    {:ok, ^expected} = Jido.Exec.run(owner, %{items: [%{value: 2}, %{value: 4}], offset: 1})
  end
  IO.puts("INLINE_RESULT=" <> JSON.encode!(%{identity: identity, result: expected}))
  """

  @timed_compile """
  started = System.monotonic_time()
  result = Mix.Task.run("compile", ["--warnings-as-errors"])
  elapsed = System.monotonic_time() - started
  IO.puts("DSL_COMPILE_RESULT=" <> JSON.encode!(%{
    elapsed_ns: System.convert_time_unit(elapsed, :native, :nanosecond),
    compile_result: inspect(result)
  }))
  """

  def run(output, count) do
    File.mkdir_p!(output)
    # This unique directory is owned by this invocation only.
    temporary =
      Path.join(
        System.tmp_dir!(),
        "jido-dsl-compile-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    File.mkdir!(temporary)
    source = identity()

    try do
      samples =
        for workload <- ["ordinary_map", "inline_consumer"], sample <- 1..count do
          directory = Path.join(temporary, "#{workload}-#{sample}")
          File.mkdir!(directory)
          fixture = Build.setup(%{tmp_dir: directory}) |> prepare(workload)

          {rows, _previous} =
            Enum.map_reduce(["cold", "changed", "no_change"], nil, fn phase, previous ->
              if phase == "changed", do: change(fixture, workload)

              {log, status} =
                Build.mix(fixture, [
                  "run",
                  "--no-compile",
                  "--no-start",
                  Path.join(fixture.scripts, "timed_compile.exs")
                ])

              File.write!(Path.join(output, "#{workload}-#{sample}-#{phase}.log"), log)
              if status != 0, do: raise(log)
              [_, json] = Regex.run(~r/^DSL_COMPILE_RESULT=(.*)$/m, log)
              timing = JSON.decode!(json)
              artifacts = artifacts(fixture)
              generated_count = if workload == "ordinary_map", do: 0, else: 8

              if artifacts.generated_count != generated_count,
                do: raise("unexpected generated BEAM count")

              if phase == "no_change" do
                if artifacts != previous.artifacts or log =~ "Compiling",
                  do: raise("no-change compile rebuilt artifacts")
              end

              # These checks run in another fresh VM, entirely outside compilation timing.
              offset =
                if phase == "cold", do: 1, else: if(workload == "ordinary_map", do: 2, else: 100)

              check = Build.probe(fixture, offset)

              if phase == "no_change" and check != previous.check,
                do: raise("no-change result differs")

              row = %{
                workload: workload,
                sample: sample,
                phase: phase,
                timing: timing,
                artifacts: artifacts,
                check: check
              }

              {row, row}
            end)

          rows
        end
        |> List.flatten()

      if identity() != source, do: raise("source or tools changed during measurement")

      cases =
        for workload <- ["ordinary_map", "inline_consumer"],
            phase <- ["cold", "changed", "no_change"] do
          raw =
            for row <- samples,
                row.workload == workload and row.phase == phase,
                do: row.timing["elapsed_ns"]

          sorted = Enum.sort(raw)
          middle = div(length(sorted), 2)

          median =
            if rem(length(sorted), 2) == 1,
              do: Enum.at(sorted, middle),
              else: (Enum.at(sorted, middle - 1) + Enum.at(sorted, middle)) / 2

          %{workload: workload, phase: phase, elapsed_ns: %{raw: raw, median: median}}
        end

      report = %{
        schema_version: 1,
        source: source,
        environment: %{
          elixir: System.version(),
          otp: to_string(:erlang.system_info(:otp_release)),
          erts: to_string(:erlang.system_info(:system_version)),
          architecture: to_string(:erlang.system_info(:system_architecture)),
          hostname: command("hostname", []),
          os: command("uname", ["-srv"])
        },
        settings: %{samples: count, child_erl_flags: "+S 2:2 +SDcpu 1 +SDio 1", mix_env: "test"},
        method:
          "Fresh VM per compile; time Mix.Task.run compile only; prebuilt dependencies on code path; separate fresh VM for checks.",
        limits: [
          "Cold means an empty consumer build, not an empty OS file cache. Mix consumer compiler startup is included; VM startup and checks are excluded.",
          "Ordinary workload has one explicit Action and two equivalent Map Flows. Inline workload reuses the fixed eight-target host fixture, including host macros.",
          "Changed ordinary source adds one to both Map params. Changed inline source changes the body macro offset from 1 to 100.",
          "No memory or reductions measurement. Use the existing execution benchmark for runtime measurements.",
          "Repeat on an idle host. One report does not establish baseline noise or satisfy the five-pair comparison protocol."
        ],
        cases: cases,
        samples: samples
      }

      File.write!(Path.join(output, "dsl_compile.json"), JSON.encode!(report))
      IO.puts("Wrote #{output}/dsl_compile.json")
    after
      File.rm_rf!(temporary)
    end
  end

  defp prepare(fixture, "ordinary_map") do
    for path <- Path.wildcard(Path.join(fixture.app, "lib/*.ex")), do: File.rm!(path)
    source = Path.join(fixture.app, "lib/ordinary.ex")
    File.write!(source, @ordinary)
    File.touch!(source, 946_684_800)

    File.write!(
      Path.join(fixture.app, "variants/ordinary_changed.ex"),
      String.replace(@ordinary, "input(:offset)}", "input(:offset) + 1}")
    )

    File.write!(Path.join(fixture.scripts, "probe.exs"), @ordinary_check)
    prepare(fixture, "inline_consumer")
  end

  defp prepare(fixture, "inline_consumer") do
    File.write!(Path.join(fixture.scripts, "timed_compile.exs"), @timed_compile)
    fixture
  end

  defp change(fixture, "ordinary_map"),
    do: Build.replace(fixture, "ordinary_changed.ex", "ordinary.ex")

  defp change(fixture, "inline_consumer"),
    do: Build.replace(fixture, "body_macro_changed.ex", "body_macro.ex")

  defp artifacts(fixture) do
    files = Path.wildcard(Path.join(Build.ebin(fixture), "*.beam")) |> Enum.sort()
    generated_names = Build.beams(fixture)
    generated = Enum.filter(files, &(Path.basename(&1) in generated_names))

    %{
      count: length(files),
      bytes: Enum.sum(Enum.map(files, &File.stat!(&1).size)),
      generated_count: length(generated),
      generated_bytes: Enum.sum(Enum.map(generated, &File.stat!(&1).size)),
      beams:
        Map.new(
          files,
          &{Path.basename(&1), %{bytes: File.stat!(&1).size, sha256: hash(File.read!(&1))}}
        )
    }
  end

  defp identity do
    untracked =
      command("git", ["ls-files", "--others", "--exclude-standard", "-z"])
      |> String.split(<<0>>, trim: true)

    patch = command("git", ["diff", "--binary", "HEAD"])

    tools =
      ([__ENV__.file, "test/support/inline_build.ex"] ++
         Path.wildcard("test/fixtures/inline_consumer/**/*"))
      |> Enum.filter(&File.regular?/1)
      |> Enum.sort()

    runtime =
      command("git", ["ls-files", "-z", "lib", "config", "mix.exs", "mix.lock"])
      |> String.split(<<0>>, trim: true)

    %{
      commit: String.trim(command("git", ["rev-parse", "HEAD"])),
      patch_sha256: hash([patch | Enum.map(untracked, &[&1, <<0>>, File.read!(&1), <<0>>])]),
      untracked_files: untracked,
      runtime_source_sha256:
        hash(
          Enum.map(
            runtime,
            &[&1, <<0>>, if(File.regular?(&1), do: File.read!(&1), else: "DELETED"), <<0>>]
          )
        ),
      lock_sha256: hash(File.read!("mix.lock")),
      tools: Map.new(tools, &{Path.relative_to_cwd(&1), hash(File.read!(&1))}),
      prebuilt_action_beam_sha256: hash(File.read!(to_string(:code.which(Jido.Action))))
    }
  end

  defp hash(data), do: :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)

  defp command(executable, args) do
    {result, 0} = System.cmd(executable, args)
    result
  end
end

{output, count} =
  case System.argv() do
    [output] -> {output, 5}
    [output, count] -> {output, String.to_integer(count)}
    _ -> raise("usage: dsl_compile_probe.exs OUTPUT [SAMPLES]")
  end

if count not in 1..50, do: raise("SAMPLES must be between 1 and 50")
JidoActionBench.DSLCompileProbe.run(output, count)
