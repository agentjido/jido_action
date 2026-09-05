defmodule Jido.Action.InlineHostBuildTest do
  use ExUnit.Case, async: false

  alias JidoActionTest.InlineBuild, as: Build

  @moduletag :tmp_dir
  @moduletag timeout: 180_000

  setup context do
    fixture = Build.setup(context)
    on_exit(fn -> File.rm_rf!(context.tmp_dir) end)
    {:ok, fixture: fixture}
  end

  test "a clean release loads every inline role with consumer source removed", %{fixture: fixture} do
    {output, status} = Build.mix(fixture, ["release"])
    assert status == 0, output
    assert length(Build.beams(fixture)) == 15

    # The package remains in the isolated build directory. Remove the full
    # consumer project, including its source variants and Mix file.
    File.rm_rf!(fixture.app)
    File.mkdir!(fixture.app)
    result = Build.release_probe(fixture)
    assert result["count"] == 15
    assert map_size(result["roles"]["targets"]) == 9
    assert Map.keys(result["steps"]["targets"]) == ["first", "second"]
  end

  test "ordinary compilation rejects an Action without run/2", %{fixture: fixture} do
    Build.replace(fixture, "missing_action.ex", "missing_action.ex")
    {output, status} = Build.mix(fixture, ["compile"])
    assert status != 0
    assert output =~ "run/2"
    assert output =~ "implementation not provided"
  end

  test "body macro edits rebuild unchanged owners and recover after failed compilation", %{
    fixture: fixture
  } do
    Build.compile!(fixture)
    refute Build.compile!(fixture) =~ "Compiling"
    initial = Build.probe(fixture)
    beams = Build.beams(fixture)

    owners =
      for name <- ["roles", "steps"], into: %{} do
        path = Path.join([fixture.app, "lib", name <> ".ex"])
        {path, {File.read!(path), File.stat!(path, time: :posix).mtime}}
      end

    owner_beam = Path.join(Build.ebin(fixture), "Elixir.InlineConsumer.Roles.beam")
    initial_beam = File.read!(owner_beam)

    Build.replace(fixture, "body_macro_changed.ex", "body_macro.ex")
    assert Build.compile!(fixture) =~ "Compiling"

    for {path, {source, mtime}} <- owners do
      assert File.read!(path) == source
      assert File.stat!(path, time: :posix).mtime == mtime
    end

    refute File.read!(owner_beam) == initial_beam
    assert Build.probe(fixture, 100) == initial
    assert Build.beams(fixture) == beams

    Build.replace(fixture, "body_macro_invalid.ex", "body_macro.ex")
    {output, status} = Build.mix(fixture, ["compile", "--warnings-as-errors"])
    assert status != 0
    assert output =~ "missing_inline_body_function"

    Build.replace(fixture, "body_macro_changed.ex", "body_macro.ex")
    Build.compile!(fixture)
    assert Build.probe(fixture, 100) == initial
    assert Build.beams(fixture) == beams
  end

  test "renaming a Choice and removing an option removes only its old targets", %{
    fixture: fixture
  } do
    Build.compile!(fixture)
    initial = Build.probe(fixture)
    initial_beams = Build.beams(fixture)

    Build.replace(fixture, "roles_changed.ex", "roles.ex")
    Build.compile!(fixture)
    changed = Build.probe(fixture)
    before = initial["roles"]["targets"]
    after_change = changed["roles"]["targets"]
    nested = ["option", "other", "fallback"]

    assert Map.drop(after_change, nested) == Map.drop(before, nested)
    assert changed["steps"] == initial["steps"]
    refute Map.has_key?(after_change, "other")
    for name <- ["option", "fallback"], do: refute(after_change[name] == before[name])

    assert Build.beams(fixture) -- initial_beams ==
             target_beams(after_change, ["option", "fallback"])

    assert initial_beams -- Build.beams(fixture) == target_beams(before, nested)
  end

  test "Step syntax changes preserve identity and renamed Steps remove stale artifacts", %{
    fixture: fixture
  } do
    Build.compile!(fixture)
    initial = Build.probe(fixture)
    beams = Build.beams(fixture)

    Build.replace(fixture, "steps_nested.ex", "steps.ex")
    Build.compile!(fixture)
    assert Build.probe(fixture) == initial
    assert Build.beams(fixture) == beams

    Build.replace(fixture, "steps_reduced.ex", "steps.ex")
    Build.compile!(fixture)
    changed = Build.probe(fixture)
    assert changed["roles"] == initial["roles"]
    assert Map.keys(changed["steps"]["targets"]) == ["renamed"]

    assert beams -- Build.beams(fixture) ==
             target_beams(initial["steps"]["targets"], ["first", "second"])

    assert Build.beams(fixture) -- beams == target_beams(changed["steps"]["targets"], ["renamed"])
  end

  defp target_beams(targets, names),
    do: names |> Enum.map(&(targets[&1] <> ".beam")) |> Enum.sort()
end
