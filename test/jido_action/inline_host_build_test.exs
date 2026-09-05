defmodule Jido.Action.InlineHostBuildTest do
  use ExUnit.Case, async: false

  @moduletag timeout: 90_000
  @wrapper_prefix "Elixir.Jido.Action.Generated.Inline."

  setup do
    directory =
      Path.join(
        System.tmp_dir!(),
        "jido_inline_host_build_" <> Base.url_encode64(:crypto.strong_rand_bytes(12))
      )

    File.mkdir!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)
    File.mkdir!(Path.join(directory, "lib"))

    File.write!(Path.join(directory, "mix.exs"), """
    defmodule InlineHostBuild.MixProject do
      use Mix.Project
      def project do
        [app: :inline_host_build, version: "0.1.0", deps: [],
         releases: [inline_host_build: [include_erts: false]]]
      end
      def application, do: [extra_applications: [:jido_action]]
    end
    """)

    # Compile the same public-only adapter as consumer source, under a distinct
    # namespace. The inherited test-support BEAM cannot satisfy this build.
    host_source =
      "../support/fixtures/action/inline_host.ex"
      |> Path.expand(__DIR__)
      |> File.read!()
      |> String.replace("JidoActionTest.Fixtures.Action.InlineHost", "InlineConsumer.Host")

    File.write!(Path.join(directory, "lib/host.ex"), host_source)
    File.write!(Path.join(directory, "lib/owners.ex"), owner_source())

    paths =
      :code.get_path()
      |> Enum.map(&(&1 |> to_string() |> Path.expand()))
      |> Enum.filter(&(Path.basename(&1) == "ebin" and File.dir?(&1)))

    {:ok, directory: directory, paths: paths}
  end

  test "a separate application emits and loads both Action modes and late declarations",
       fixture do
    {output, status} = child(fixture, ~s|Mix.CLI.main(["compile", "--warnings-as-errors"])|)
    assert status == 0, output

    beams = File.ls!(ebin(fixture))
    assert "Elixir.InlineConsumer.Host.beam" in beams
    assert "Elixir.InlineConsumer.Host.Field.beam" in beams
    assert "Elixir.InlineConsumer.Bound.beam" in beams
    assert "Elixir.InlineConsumer.Callback.beam" in beams
    assert Enum.count(beams, &String.starts_with?(&1, @wrapper_prefix)) == 4

    # The fresh VM must run with artifacts only, with no consumer source left.
    File.rm_rf!(Path.join(fixture.directory, "lib"))
    {output, status} = child(fixture, probe_source(fixture))
    assert status == 0, output
    assert output =~ "INLINE_HOST_BUILD_OK"
  end

  test "a missing Action callback fails ordinary compilation", fixture do
    File.write!(Path.join(fixture.directory, "lib/missing_action.ex"), """
    defmodule InlineConsumer.MissingAction do
      use Jido.Action, name: "missing_action"
    end
    """)

    {output, status} = child(fixture, ~s|Mix.CLI.main(["compile"])|)
    assert status != 0
    assert output =~ "run/2"
    assert output =~ "implementation not provided"
  end

  test "a release includes shared host and Flow targets without consumer source", fixture do
    File.write!(Path.join(fixture.directory, "lib/flow.ex"), """
    defmodule InlineConsumer.Flow do
      use Jido.Flow, name: "release_flow"
      flow do
        step "first", value <- input(:value) do
          {:ok, %{value: value + 1}}
        end
        step "second" do
          action value <- result("first", :value) do
            {:ok, %{value: value * 2}}
          end
        end
        output result("second")
      end
    end
    """)

    {output, status} = child(fixture, ~s|Mix.CLI.main(["release"])|)
    assert status == 0, output

    release = Path.join(fixture.directory, "_build/test/rel/inline_host_build")
    release_ebin = Path.join(release, "lib/inline_host_build-0.1.0/ebin")
    beams = File.ls!(release_ebin)
    assert Enum.count(beams, &String.starts_with?(&1, @wrapper_prefix)) == 6
    refute Enum.any?(beams, &String.starts_with?(&1, "Elixir.Jido.Flow.Generated.InlineStep."))
    File.rm_rf!(Path.join(fixture.directory, "lib"))

    script = """
    spawn(fn -> receive do after 30_000 -> System.halt(124) end end)
    false = File.dir?("lib")
    {:ok, _} = Application.ensure_all_started(:inline_host_build)
    {:ok, modules} = :application.get_key(:inline_host_build, :modules)
    targets = Enum.filter(modules, &String.starts_with?(Atom.to_string(&1), #{inspect(@wrapper_prefix)}))
    6 = length(targets)
    false = :code.is_loaded(InlineConsumer.Flow)
    for target <- targets do
      {:module, ^target} = Code.ensure_loaded(target)
      {owner, path} = target.__jido_inline_action__()
      ^target = Jido.Action.Inline.target!(owner, path)
    end
    flow = InlineConsumer.Flow
    first = flow.step_action("first")
    second = flow.step_action("second")
    true = first != second
    ^first = Jido.Action.Inline.target!(flow, host: Jido.Flow, step: "first", role: :action)
    ^second = Jido.Action.Inline.target!(flow, host: Jido.Flow, step: "second", role: :action)
    registry = Jido.Flow.Registry.new!(%{"actions/first/v1" => {:action, first}})
    {:ok, ^first} = Jido.Flow.Registry.resolve(registry, "actions/first/v1", :action)
    {:ok, %{value: 4}} = Jido.Exec.run(first, %{value: 3})
    {:ok, %{value: 8}} = Jido.Exec.run(flow, %{value: 3})
    {:ok, %{message: "release:[7]"}} =
      InlineConsumer.Host.run(InlineConsumer.Bound, "bound", %{value: 3}, %{prefix: "release:"})
    {:ok, %{message: "release:[4]"}} =
      InlineConsumer.Host.run(InlineConsumer.Callback, "callback", %{}, %{prefix: "release:"})
    IO.puts("INLINE_RELEASE_OK")
    """

    {output, status} =
      System.cmd(Path.join(release, "bin/inline_host_build"), ["eval", script],
        cd: fixture.directory,
        stderr_to_stdout: true,
        env: [{"ERL_FLAGS", "+S 2:2 +SDcpu 1 +SDio 1"}, {"ELIXIR_ERL_OPTIONS", nil}]
      )

    assert status == 0, output
    assert output =~ "INLINE_RELEASE_OK"
  end

  defp owner_source do
    """
    defmodule InlineConsumer.Bound do
      use InlineConsumer.Host, mode: :bound, fields: [:value]
      @description "Compiled bound action"
      @offset 1
      action "bound", value <- field(:value) * 2,
        name: "shared_metadata", description: @description,
        schema: Zoi.object(%{value: Zoi.integer()}),
        output_schema: Zoi.object(%{message: Zoi.string()}), context: ctx do
        {:ok, %{message: ctx.prefix <> private_helper(value + @offset)}}
      end
      defp private_helper(value), do: decorate(Integer.to_string(value))
    end

    defmodule InlineConsumer.DeclarationHooks do
      defmacro __before_compile__(_env) do
        quote do
          action "late_first", %{value: value}, name: "shared_metadata", context: ctx do
            {:ok, %{message: ctx.prefix <> private_helper(value + 1)}}
          end
          action "late_second", %{value: value}, name: "shared_metadata", context: ctx do
            {:ok, %{message: ctx.prefix <> private_helper(value + 2)}}
          end
        end
      end
    end

    defmodule InlineConsumer.Callback do
      use InlineConsumer.Host, mode: :callback
      @before_compile InlineConsumer.DeclarationHooks
      action "callback", %{value: value}, name: "shared_metadata",
        schema: Zoi.object(%{value: Zoi.integer() |> Zoi.default(4)}),
        output_schema: Zoi.object(%{message: Zoi.string()}), context: ctx do
        {:ok, %{message: ctx.prefix <> private_helper(value)}}
      end
      defp private_helper(value), do: decorate(Integer.to_string(value))
    end
    """
  end

  defp probe_source(fixture) do
    """
    {:ok, _} = Application.ensure_all_started(:inline_host_build)
    false = File.dir?("lib")
    host = :"Elixir.InlineConsumer.Host"
    bound_owner = :"Elixir.InlineConsumer.Bound"
    callback_owner = :"Elixir.InlineConsumer.Callback"
    false = :code.is_loaded(host)
    owners = [bound_owner, callback_owner]
    for owner <- owners, do: false = :code.is_loaded(owner)
    {:ok, app_modules} = :application.get_key(:inline_host_build, :modules)
    true = host in app_modules
    for owner <- owners, do: true = owner in app_modules

    # Discover target atoms from emitted BEAM metadata, before owner lookup.
    targets =
      for file <- File.ls!(#{inspect(ebin(fixture))}),
          String.starts_with?(file, #{inspect(@wrapper_prefix)}),
          String.ends_with?(file, ".beam") do
        path = Path.join(#{inspect(ebin(fixture))}, file)
        target = path |> String.to_charlist() |> :beam_lib.info() |> Keyword.fetch!(:module)
        false = :code.is_loaded(target)
        true = target in app_modules
        {:module, ^target} = Code.ensure_loaded(target)
        "shared_metadata" = target.name()
        target
      end
    4 = length(targets)
    for owner <- owners, do: false = :code.is_loaded(owner)

    # A wrapper can load its owner and call its private-helper-backed body.
    for target <- targets do
      {:ok, %{message: message}} = Jido.Exec.run(target, %{value: 5}, %{prefix: "artifact:"})
      true = message in ["artifact:[6]", "artifact:[5]", "artifact:[7]"]
    end
    for owner <- owners do
      {:file, _} = :code.is_loaded(owner)
      {:module, ^owner} = Code.ensure_loaded(owner)
    end

    bound = bound_owner.action_target("bound")
    callback = callback_owner.action_target("callback")
    late_first = callback_owner.action_target("late_first")
    late_second = callback_owner.action_target("late_second")
    true = bound != callback
    true = Enum.sort(targets) == Enum.sort([bound, callback, late_first, late_second])
    "Compiled bound action" = bound.description()
    {:ok, %{message: "host:[7]"}} = host.run(bound_owner, "bound", %{value: 3}, %{prefix: "host:"})
    {:ok, %{message: "default:[4]"}} = host.run(callback_owner, "callback", %{}, %{prefix: "default:"})
    {:ok, %{message: "reuse:[10]"}} = Jido.Exec.run(bound, %{value: 9}, %{prefix: "reuse:"})
    {:ok, %{message: "late:[6]"}} = Jido.Exec.run(late_first, %{value: 5}, %{prefix: "late:"})
    {:ok, %{message: "late:[7]"}} = Jido.Exec.run(late_second, %{value: 5}, %{prefix: "late:"})
    {:error, %Jido.Action.Error.InvalidInputError{}} = Jido.Exec.run(callback, %{value: "bad"})

    # Warm error machinery, then check lookup without an atom allocation.
    lookup_missing = fn name ->
      try do
        bound_owner.action_target(name)
        raise "unknown lookup succeeded"
      rescue
        ArgumentError -> :ok
      end
    end
    :ok = lookup_missing.("warmup")
    names = Enum.map(1..20, &("missing_" <> Integer.to_string(&1)))
    atom_count = :erlang.system_info(:atom_count)
    for name <- names, do: :ok = lookup_missing.(name)
    ^atom_count = :erlang.system_info(:atom_count)
    IO.puts("INLINE_HOST_BUILD_OK")
    """
  end

  defp ebin(fixture), do: Path.join(fixture.directory, "_build/test/lib/inline_host_build/ebin")

  defp child(fixture, script) do
    # Bound the OS child independently of the ExUnit test timeout.
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
