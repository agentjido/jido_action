defmodule Jido.Flow.DSL.InlineStepBuildTest do
  use ExUnit.Case, async: false

  @moduletag timeout: 180_000
  @wrapper_prefix "Elixir.Jido.Flow.Generated.InlineStep."
  @owner InlineBuild.Flow

  setup do
    directory =
      Path.join(
        System.tmp_dir!(),
        "jido_inline_build_" <> Base.url_encode64(:crypto.strong_rand_bytes(12))
      )

    File.mkdir!(directory)
    File.mkdir!(Path.join(directory, "lib"))
    on_exit(fn -> File.rm_rf!(directory) end)

    File.write!(Path.join(directory, "mix.exs"), """
    defmodule InlineBuild.MixProject do
      use Mix.Project
      def project, do: [app: :inline_build, version: "0.1.0", deps: []]
      def application, do: [extra_applications: [:jido_action]]
    end
    """)

    paths =
      :code.get_path()
      |> Enum.map(&(&1 |> to_string() |> Path.expand()))
      |> Enum.filter(&(Path.basename(&1) == "ebin" and File.dir?(&1)))

    {:ok, directory: directory, paths: paths}
  end

  test "Mix emits attribute-named targets and removes old targets through rebuild and repair",
       fixture do
    write_source(fixture, "flow.ex", flow_source("first", 1))
    assert_compile(fixture)
    [first, second] = initial_targets = wrapper_beams(fixture)
    assert length(initial_targets) == 2

    initial = probe(fixture, "first", 3, 6)
    assert initial["names"] == ["first", "second"]
    assert initial["target"] in Enum.map([first, second], &Path.rootname/1)

    # A body-only edit retains target identity but changes the deployed work.
    write_source(fixture, "flow.ex", flow_source("first", 20))
    assert_compile(fixture)
    changed = probe(fixture, "first", 22, 44)
    assert changed["target"] == initial["target"]
    assert changed["semantic_identity"] == initial["semantic_identity"]
    assert wrapper_beams(fixture) == initial_targets

    # Rename and removal must update both the emitted beams and the static index.
    write_source(fixture, "flow.ex", flow_source("renamed", 20))
    assert_compile(fixture)
    renamed = probe(fixture, "renamed", 22, 44, ["first"])
    refute renamed["target"] == initial["target"]
    refute (initial["target"] <> ".beam") in wrapper_beams(fixture)
    assert length(wrapper_beams(fixture)) == 2

    write_source(fixture, "flow.ex", flow_source("renamed", 20, second?: false))
    assert_compile(fixture)
    removed = probe(fixture, "renamed", 22, 22, ["first", "second"])
    assert removed["names"] == ["renamed"]
    assert wrapper_beams(fixture) == [renamed["target"] <> ".beam"]

    # Failed owner compilation can leave modules loaded in that compiler VM.
    # A later ordinary Mix build must recover without a foreign-owner error.
    write_source(fixture, "flow.ex", flow_source("renamed", :invalid, second?: false))
    {output, status} = compile(fixture)
    assert status != 0
    assert output =~ "missing_inline_body_function"

    write_source(fixture, "flow.ex", flow_source("renamed", 30, second?: false))
    assert_compile(fixture)
    repaired = probe(fixture, "renamed", 32, 32, ["first", "second"])
    assert repaired["target"] == renamed["target"]
    assert wrapper_beams(fixture) == [repaired["target"] <> ".beam"]

    write_source(fixture, "flow.ex", flow_source("failed_name", :invalid, second?: false))
    {output, status} = compile(fixture)
    assert status != 0
    assert output =~ "missing_inline_body_function"
    write_source(fixture, "flow.ex", flow_source("recovered", 400, second?: false))
    assert_compile(fixture)
    recovered = probe(fixture, "recovered", 402, 402, ["renamed", "failed_name", "second"])
    assert wrapper_beams(fixture) == [recovered["target"] <> ".beam"]
  end

  test "a changed body macro recompiles the unchanged owner through Mix dependency tracking",
       fixture do
    write_source(fixture, "macro.ex", macro_source(1))
    write_source(fixture, "flow.ex", flow_source("first", :macro))
    assert_compile(fixture)
    refute assert_compile(fixture) =~ "Compiling"
    initial = probe(fixture, "first", 3, 6)
    owner_path = Path.join(fixture.directory, "lib/flow.ex")
    owner_source = File.read!(owner_path)
    owner_stat = File.stat!(owner_path, time: :posix)
    owner_beam = File.read!(Path.join(ebin(fixture), "Elixir.InlineBuild.Flow.beam"))

    write_source(fixture, "macro.ex", macro_source(100))
    output = assert_compile(fixture)

    assert output =~ "Compiling"
    assert File.read!(owner_path) == owner_source
    assert File.stat!(owner_path, time: :posix).mtime == owner_stat.mtime
    refute File.read!(Path.join(ebin(fixture), "Elixir.InlineBuild.Flow.beam")) == owner_beam
    changed = probe(fixture, "first", 102, 204)
    assert changed["target"] == initial["target"]
  end

  defp flow_source(name, version, options \\ []) do
    body =
      case version do
        :invalid -> "missing_inline_body_function(value)"
        :macro -> "InlineBuild.BodyMacro.increment(value)"
        value -> "value + #{value}"
      end

    first =
      if Keyword.get(options, :nested?, false) do
        """
        step @step_name do
          action value <- input(:value) do
            {:ok, %{value: #{body}}}
          end
        end
        """
      else
        """
        step @step_name, value <- input(:value) do
          {:ok, %{value: #{body}}}
        end
        """
      end

    second =
      if Keyword.get(options, :second?, true) do
        """
        step "second", value <- result(#{inspect(name)}, :value) do
          {:ok, %{value: value * 2}}
        end
        output(result("second"))
        """
      else
        "output(result(#{inspect(name)}))"
      end

    """
    defmodule #{inspect(@owner)} do
      use Jido.Flow, name: "inline_build"
      @step_name #{inspect(name)}
      #{if version == :macro, do: "require InlineBuild.BodyMacro", else: ""}
      flow do
        #{first}
        #{second}
      end
    end
    """
  end

  test "nested Step wrappers ship, track body macros, and repair through ordinary Mix builds",
       fixture do
    write_source(fixture, "macro.ex", macro_source(1))
    write_source(fixture, "flow.ex", flow_source("first", :macro))
    assert_compile(fixture)
    legacy = probe(fixture, "first", 3, 6)
    legacy_beams = wrapper_beams(fixture)

    write_source(fixture, "flow.ex", flow_source("first", :macro, nested?: true))
    assert_compile(fixture)
    nested = probe(fixture, "first", 3, 6)
    assert nested == legacy
    assert wrapper_beams(fixture) == legacy_beams

    write_source(fixture, "macro.ex", macro_source(10))
    assert assert_compile(fixture) =~ "Compiling"
    changed = probe(fixture, "first", 12, 24)
    assert changed["target"] == nested["target"]

    write_source(fixture, "flow.ex", flow_source("first", :invalid, nested?: true))
    {output, status} = compile(fixture)
    assert status != 0
    assert output =~ "missing_inline_body_function"

    write_source(fixture, "flow.ex", flow_source("first", 20, nested?: true))
    assert_compile(fixture)
    repaired = probe(fixture, "first", 22, 44)
    assert repaired["target"] == nested["target"]
    assert wrapper_beams(fixture) == legacy_beams
  end

  defp macro_source(increment) do
    """
    defmodule InlineBuild.BodyMacro do
      defmacro increment(value) do
        quote do: unquote(value) + #{increment}
      end
    end
    """
  end

  defp write_source(fixture, file, source) do
    path = Path.join([fixture.directory, "lib", file])
    mtime = if File.exists?(path), do: File.stat!(path, time: :posix).mtime + 1, else: 946_684_800
    File.write!(path, source)
    # Advance only this source's recorded mtime. Use past times so same-second
    # edits are deterministic without forcing unchanged owners or touching Mix state.
    File.touch!(path, mtime)
  end

  defp assert_compile(fixture) do
    {output, status} = compile(fixture)
    assert status == 0, output
    output
  end

  defp compile(fixture), do: child(fixture, ~s|Mix.CLI.main(["compile", "--warnings-as-errors"])|)

  defp probe(fixture, name, direct_value, flow_value, missing \\ []) do
    # The wrapper module atom comes from a real emitted beam, not owner lookup.
    # This process has no source compilation call and starts with the owner unloaded.
    script = """
    {:ok, _} = Application.ensure_all_started(:jido_action)
    owner = :"Elixir.InlineBuild.Flow"
    {:before_registry, false} = {:before_registry, :code.is_loaded(owner)}
    targets =
      for file <- File.ls!(#{inspect(ebin(fixture))}),
          String.starts_with?(file, #{inspect(@wrapper_prefix)}),
          String.ends_with?(file, ".beam"),
          do: file |> Path.rootname() |> String.to_atom()
    target = Enum.find(targets, &(&1.name() == #{inspect(name)}))
    registry = Jido.Flow.Registry.new!(%{"inline/step" => {:action, target}})
    {:ok, ^target} = Jido.Flow.Registry.resolve(registry, "inline/step", :action)
    {:after_registry, false} = {:after_registry, :code.is_loaded(owner)}
    {:ok, %{value: #{direct_value}}} = Jido.Exec.run(target, %{value: 2})
    ^target = apply(owner, :step_action, [#{inspect(name)}])
    {:ok, %{value: #{flow_value}}} = Jido.Exec.run(owner, %{value: 2})
    for name <- #{inspect(missing)} do
      try do
        apply(owner, :step_action, [name])
        raise "stale lookup entry"
      rescue
        ArgumentError -> :ok
      end
    end
    {:ok, semantic_identity} = Jido.Flow.semantic_identity(apply(owner, :flow, []))
    IO.puts("INLINE_BUILD_RESULT=" <> JSON.encode!(%{
      "target" => Atom.to_string(target),
      "semantic_identity" => semantic_identity,
      "names" => Enum.map(apply(owner, :flow, []).components, & &1.name)
    }))
    """

    {output, status} = child(fixture, script)
    assert status == 0, output
    [_, json] = Regex.run(~r/INLINE_BUILD_RESULT=(.*)/, output)
    JSON.decode!(json)
  end

  defp wrapper_beams(fixture) do
    fixture
    |> ebin()
    |> File.ls!()
    |> Enum.filter(&(String.starts_with?(&1, @wrapper_prefix) and String.ends_with?(&1, ".beam")))
    |> Enum.sort()
  end

  defp ebin(fixture), do: Path.join(fixture.directory, "_build/test/lib/inline_build/ebin")

  defp child(fixture, script) do
    # Bound the child VM itself. ExUnit timeouts alone cannot stop an OS child.
    watchdog = "spawn(fn -> receive do after 30_000 -> System.halt(124) end end)\n"
    paths = [ebin(fixture) | fixture.paths]
    args = Enum.flat_map(paths, &["-pa", &1]) ++ ["-e", watchdog <> script]

    System.cmd(System.find_executable("elixir"), args,
      cd: fixture.directory,
      stderr_to_stdout: true,
      env: [
        {"MIX_ENV", "test"},
        {"MIX_BUILD_PATH", Path.join(fixture.directory, "_build/test")},
        {"MIX_DEPS_PATH", nil},
        {"MIX_TARGET", "host"},
        {"ERL_FLAGS", "+S 2:2 +SDcpu 1 +SDio 1"},
        {"ELIXIR_ERL_OPTIONS", nil}
      ]
    )
  end
end
