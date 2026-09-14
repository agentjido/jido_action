Code.require_file("support/components.ex", __DIR__)
Code.require_file("support/hostile.ex", __DIR__)
Code.require_file("support/extension.ex", __DIR__)

defmodule JidoActionTest.Authoring.ExtensionTest do
  use ExUnit.Case, async: false
  @moduletag :authoring

  alias JidoActionTest.Authoring.Extension

  test "a host extension expands to ordinary canonical source declarations" do
    assert Extension.Extended.flow() == Extension.Plain.flow()

    assert Jido.Exec.run(Extension.Extended, %{value: 7}, %{observer: self()}) ==
             {:ok, %{id: "observed", value: 7}}

    assert_receive {:hostile_action, %{id: "observed", value: 7}}
  end

  test "an extension error points to the source call" do
    source = """
    defmodule JidoActionTest.Authoring.Extension.Invalid do
      use Jido.Flow,
        name: "authoring_invalid_extension",
        extensions: [JidoActionTest.Authoring.Extension.WatchStep]

      flow do
        watch_step("observed", result("missing"))
        output result("observed")
      end
    end
    """

    error =
      assert_raise CompileError, fn ->
        Code.compile_string(source, "authoring_extension_invalid.ex")
      end

    assert error.file == "authoring_extension_invalid.ex"
    assert error.line == 7
    assert error.description =~ "unknown component"
  end
end
