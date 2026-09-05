defmodule Jido.Flow.DSL.InlineActionBuildTest do
  use ExUnit.Case, async: false

  @moduletag timeout: 180_000
  @prefixes ["Elixir.Jido.Action.Generated.Inline."]

  setup do
    directory =
      Path.join(
        System.tmp_dir!(),
        "jido_inline_roles_build_" <> Base.url_encode64(:crypto.strong_rand_bytes(12))
      )

    File.mkdir!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)
    File.mkdir!(Path.join(directory, "lib"))

    File.write!(Path.join(directory, "mix.exs"), """
    defmodule InlineRolesBuild.MixProject do
      use Mix.Project
      def project, do: [app: :inline_roles_build, version: "0.1.0", deps: []]
      def application, do: [extra_applications: [:jido_action]]
    end
    """)

    paths =
      :code.get_path()
      |> Enum.map(&(&1 |> to_string() |> Path.expand()))
      |> Enum.filter(&(Path.basename(&1) == "ebin" and File.dir?(&1)))

    {:ok, directory: directory, paths: paths}
  end

  test "a separate application loads every Flow role from artifacts before owner lookup",
       fixture do
    write_source(fixture, "flow.ex", source())
    assert_compile(fixture)
    assert length(wrapper_beams(fixture)) == 9
    File.rm_rf!(Path.join(fixture.directory, "lib"))
    result = probe(fixture, 1, artifact_only?: true)
    assert map_size(result["targets"]) == 9
    assert result["names"] == ["seed", "mapped", "total", "route", "loop", "next"]
  end

  test "new roles keep identities across edits and remove only changed nested artifacts",
       fixture do
    write_source(fixture, "flow.ex", source())
    assert_compile(fixture)
    initial = probe(fixture, 1)
    initial_beams = wrapper_beams(fixture)

    write_source(fixture, "flow.ex", source(offset: 20, minimum: 5))
    assert_compile(fixture)
    edited = probe(fixture, 20, minimum: 5)
    assert edited["targets"] == initial["targets"]
    assert edited["identity"] == initial["identity"]
    assert wrapper_beams(fixture) == initial_beams

    write_source(fixture, "flow.ex", source(offset: 20, minimum: 5, reverse?: true, extra?: true))
    assert_compile(fixture)
    reordered = probe(fixture, 20, minimum: 5)
    assert Map.take(reordered["targets"], Map.keys(initial["targets"])) == initial["targets"]
    assert wrapper_beams(fixture) -- initial_beams == [reordered["targets"]["extra"] <> ".beam"]

    write_source(
      fixture,
      "flow.ex",
      source(offset: 20, minimum: 5, parent: "renamed", reverse?: true, extra?: true)
    )

    assert_compile(fixture)
    renamed = probe(fixture, 20, minimum: 5, missing: choice_paths("route"))
    nested = ["option", "other", "fallback"]
    assert Map.drop(renamed["targets"], nested) == Map.drop(reordered["targets"], nested)
    for role <- nested, do: refute(renamed["targets"][role] == reordered["targets"][role])

    assert Enum.sort(wrapper_beams(fixture) -- beams(reordered)) ==
             Enum.sort(Enum.map(nested, &(renamed["targets"][&1] <> ".beam")))

    assert Enum.sort(beams(reordered) -- wrapper_beams(fixture)) ==
             Enum.sort(Enum.map(nested, &(reordered["targets"][&1] <> ".beam")))

    write_source(
      fixture,
      "flow.ex",
      source(offset: 20, minimum: 5, parent: "renamed", extra?: true, other?: false)
    )

    assert_compile(fixture)

    removed =
      probe(fixture, 20,
        minimum: 5,
        missing: choice_paths("route") ++ [[choice: "renamed", option: "other", role: :action]]
      )

    assert removed["targets"] == Map.delete(renamed["targets"], "other")
    assert wrapper_beams(fixture) == Enum.sort(beams(removed))

    write_source(
      fixture,
      "flow.ex",
      source(offset: :invalid, parent: "renamed", extra?: true, other?: false)
    )

    {output, status} = compile(fixture)
    assert status != 0
    assert output =~ "missing_inline_body_function"

    write_source(
      fixture,
      "flow.ex",
      source(offset: 30, parent: "renamed", extra?: true, other?: false)
    )

    assert_compile(fixture)
    File.rm_rf!(Path.join(fixture.directory, "lib"))
    repaired = probe(fixture, 30, artifact_only?: true)
    assert repaired["targets"] == removed["targets"]
    assert wrapper_beams(fixture) == Enum.sort(beams(removed))
  end

  test "an external body macro rebuilds unchanged owners and new-role targets", fixture do
    write_source(fixture, "macro.ex", macro_source(1))
    write_source(fixture, "flow.ex", source(offset: :macro))
    assert_compile(fixture)
    refute assert_compile(fixture) =~ "Compiling"
    initial = probe(fixture, 1)
    owner_path = Path.join(fixture.directory, "lib/flow.ex")
    owner_source = File.read!(owner_path)
    owner_stat = File.stat!(owner_path, time: :posix)
    owner_beam = File.read!(Path.join(ebin(fixture), "Elixir.InlineRolesBuild.Flow.beam"))

    write_source(fixture, "macro.ex", macro_source(100))
    assert assert_compile(fixture) =~ "Compiling"
    assert File.read!(owner_path) == owner_source
    assert File.stat!(owner_path, time: :posix).mtime == owner_stat.mtime
    refute File.read!(Path.join(ebin(fixture), "Elixir.InlineRolesBuild.Flow.beam")) == owner_beam
    changed = probe(fixture, 100)
    assert changed["targets"] == initial["targets"]
    assert changed["identity"] == initial["identity"]
    assert wrapper_beams(fixture) == Enum.sort(beams(initial))
  end

  defp source(options \\ []) do
    offset = Keyword.get(options, :offset, 1)
    parent = Keyword.get(options, :parent, "route")
    minimum = Keyword.get(options, :minimum, 0)
    schema = "schema: Zoi.object(%{value: Zoi.integer() |> Zoi.min(#{minimum})})"

    body =
      case offset do
        :invalid -> "missing_inline_body_function(value)"
        :macro -> "InlineRolesBuild.BodyMacro.increment(value)"
        offset -> "value + #{offset}"
      end

    option = fn name, condition, metadata ->
      """
      option #{inspect(name)} do
        condition #{condition}
        action value <- result("total", :value), name: #{inspect(metadata)}, #{schema} do
          {:ok, %{value: adjust(value)}}
        end
      end
      """
    end

    options_source =
      [option.("selected", "input(:enabled)", "option")] ++
        if(Keyword.get(options, :other?, true),
          do: [option.("other", "false", "other")],
          else: []
        )

    options_source =
      if Keyword.get(options, :reverse?, false),
        do: Enum.reverse(options_source),
        else: options_source

    extra =
      if Keyword.get(options, :extra?, false),
        do:
          ~s|step "extra" do\n action value <- input(:value), name: "extra", #{schema}, do: {:ok, %{value: adjust(value)}}\nend|,
        else: ""

    """
    defmodule InlineRolesBuild.Flow do
      use Jido.Flow, name: "inline_roles_build"
      #{if offset == :macro, do: "require InlineRolesBuild.BodyMacro", else: ""}
      flow do
        #{extra}
        step "seed" do
          action value <- #{if Keyword.get(options, :extra?, false), do: ~s|result("extra", :value)|, else: "input(:value)"}, name: "step", #{schema}, do: {:ok, %{value: adjust(value)}}
        end
        map "mapped" do
          collection input(:items)
          action [value <- item(), seed <- result("seed", :value)], name: "map", #{schema}, do: {:ok, %{value: adjust(value) + seed * 0}}
        end
        reduce "total" do
          collection result("mapped")
          initial %{value: 0}
          action [value <- item(:value), total <- accumulator(:value)], name: "reduce", #{schema} do
            {:ok, %{value: total + adjust(value)}}
          end
        end
        choice #{inspect(parent)} do
          #{Enum.join(options_source, "\n")}
          otherwise do
            action value <- result("total", :value), name: "fallback", #{schema}, do: {:ok, %{value: adjust(value)}}
          end
        end
        iterate "loop" do
          state [], initial: result(#{inspect(parent)})
          action value <- state(:value), name: "iterate", #{schema}, do: {:ok, %{value: adjust(value)}}
          update body_result()
          repeat 1
        end
        dispatch "next" do
          decision value <- result("loop", [:state, :value]), name: "decision", #{schema}, do: {:ok, %{value: adjust(value)}}
          expander %{value: value}, name: "expander", #{schema}, do: {:ok, %{value: adjust(value)}}
        end
        output result("next")
      end
      defp adjust(value), do: #{body}
    end
    """
  end

  defp macro_source(offset) do
    """
    defmodule InlineRolesBuild.BodyMacro do
      defmacro increment(value), do: quote(do: unquote(value) + #{offset})
    end
    """
  end

  defp probe(fixture, offset, options \\ []) do
    script = """
    {:ok, _} = Application.ensure_all_started(:inline_roles_build)
    #{if Keyword.get(options, :artifact_only?, false), do: ~s|false = File.dir?("lib")|, else: ""}
    owner = :"Elixir.InlineRolesBuild.Flow"
    false = :code.is_loaded(owner)
    {:ok, app_modules} = :application.get_key(:inline_roles_build, :modules)
    true = owner in app_modules
    targets = for file <- File.ls!(#{inspect(ebin(fixture))}), String.starts_with?(file, #{inspect(@prefixes)}) do
      path = Path.join(#{inspect(ebin(fixture))}, file)
      target = path |> String.to_charlist() |> :beam_lib.info() |> Keyword.fetch!(:module)
      false = :code.is_loaded(target)
      true = target in app_modules
      {:module, ^target} = Code.ensure_loaded(target)
      {target.name(), target}
    end
    false = :code.is_loaded(owner)
    for {role, target} <- targets do
      expected = if role == "reduce", do: #{6 + offset + 10}, else: #{6 + offset}
      {:ok, %{value: ^expected}} = Jido.Exec.run(target, %{value: 6, total: 10, seed: 0})
      #{if Keyword.get(options, :minimum, 0) == 5, do: "{:error, %Jido.Action.Error.InvalidInputError{}}", else: "{:ok, _}"} = target.validate_params(%{value: 2})

      # Reuse deployed targets with new params, not the owner's source bindings.
      params = %{value: Jido.Flow.Ref.input(:replacement), total: 10, seed: 0}
      direct = Jido.Flow.new!(name: "deployed_reuse", components: [
        Jido.Flow.Step.new!(name: "reuse", action: target, params: params)
      ], output: Jido.Flow.Ref.result("reuse"))
      {:ok, ^direct} = Jido.Flow.Builder.new(name: "deployed_reuse")
        |> Jido.Flow.Builder.step("reuse", target, params)
        |> Jido.Flow.Builder.output(Jido.Flow.Ref.result("reuse"))
        |> Jido.Flow.Builder.build()
      registry = Jido.Flow.Registry.new!(%{
        "deployed/action" => {:action, target}, "schema/empty" => {:schema, []},
        "atom/value" => {:atom, :value}, "atom/total" => {:atom, :total},
        "atom/seed" => {:atom, :seed}, "atom/replacement" => {:atom, :replacement}
      })
      {:ok, document} = Jido.Flow.Codec.encode(direct, registry)
      1 = document["version"]
      {:ok, ^direct} = document |> JSON.encode!() |> JSON.decode!() |> Jido.Flow.Codec.decode(registry)
      {:ok, %{"reuse" => %{references: []}}} = Jido.Flow.dependencies(direct)
      {:ok, %{value: ^expected}} = Jido.Exec.run(direct, %{replacement: 6})
    end
    {:file, _} = :code.is_loaded(owner)
    for enabled <- [true, false] do
      {:ok, %{value: #{13 + 8 * offset}}} = Jido.Exec.run(owner, %{value: 6, items: [6, 7], enabled: enabled})
    end
    index = owner.__jido_inline_actions__()
    true = Enum.sort(Map.values(index)) == Enum.sort(Enum.map(targets, &elem(&1, 1)))
    for {path, target} <- index do
      ^target = Jido.Action.Inline.target!(owner, path)
    end
    for path <- #{inspect(Keyword.get(options, :missing, []))} do
      try do
        Jido.Action.Inline.target!(owner, [host: Jido.Flow] ++ path)
        raise "stale nested lookup"
      rescue
        ArgumentError -> :ok
      end
    end
    {:ok, identity} = Jido.Flow.semantic_identity(owner.flow())
    IO.puts("INLINE_ROLES_RESULT=" <> JSON.encode!(%{
      "targets" => Map.new(targets, fn {role, target} -> {role, Atom.to_string(target)} end),
      "identity" => identity,
      "names" => Enum.map(owner.flow().components, & &1.name)
    }))
    """

    {output, status} = child(fixture, script)
    assert status == 0, output
    [_, json] = Regex.run(~r/INLINE_ROLES_RESULT=(.*)/, output)
    JSON.decode!(json)
  end

  defp choice_paths(parent),
    do: [
      [choice: parent, option: "selected", role: :action],
      [choice: parent, option: "other", role: :action],
      [choice: parent, fallback: :otherwise, role: :action]
    ]

  defp beams(result), do: Enum.map(result["targets"], fn {_role, target} -> target <> ".beam" end)

  defp wrapper_beams(fixture),
    do:
      ebin(fixture)
      |> File.ls!()
      |> Enum.filter(&String.starts_with?(&1, @prefixes))
      |> Enum.sort()

  defp ebin(fixture), do: Path.join(fixture.directory, "_build/test/lib/inline_roles_build/ebin")

  defp write_source(fixture, file, source) do
    path = Path.join([fixture.directory, "lib", file])
    mtime = if File.exists?(path), do: File.stat!(path, time: :posix).mtime + 1, else: 946_684_800
    File.write!(path, source)
    File.touch!(path, mtime)
  end

  defp assert_compile(fixture) do
    {output, status} = compile(fixture)
    assert status == 0, output
    output
  end

  defp compile(fixture), do: child(fixture, ~s|Mix.CLI.main(["compile", "--warnings-as-errors"])|)

  defp child(fixture, script) do
    watchdog = "spawn(fn -> receive do after 30_000 -> System.halt(124) end end)\n"

    args =
      Enum.flat_map([ebin(fixture) | fixture.paths], &["-pa", &1]) ++ ["-e", watchdog <> script]

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
