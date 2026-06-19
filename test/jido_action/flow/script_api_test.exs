defmodule JidoTest.FlowScriptApiTest do
  use JidoTest.ActionCase, async: true

  alias Jido.Flow
  alias Jido.Flow.Script

  describe "public API" do
    test "parse!/2 raises parser errors" do
      assert_raise ArgumentError, ~r/step expects 2 positional arguments/, fn ->
        Script.parse!(
          """
          flow :scripted_combination do
            step :add
          end
          """,
          allowed_atoms: script_atoms()
        )
      end
    end

    test "parse_file!/2 reads and parses flow script files" do
      path =
        Path.join(System.tmp_dir!(), "jido_flow_script_#{System.unique_integer([:positive])}.exs")

      File.write!(path, flow_script("step :add, JidoTest.TestActions.Add"))

      try do
        assert %Flow{name: :scripted_combination, flow: [%{name: :add}]} =
                 Script.parse_file!(path, allowed_atoms: script_atoms())
      after
        File.rm(path)
      end
    end

    test "parse/2 returns syntax and top-level form errors" do
      assert {:error, %ArgumentError{message: syntax_message}} =
               Script.parse("flow :scripted_combination do\n", allowed_atoms: script_atoms())

      assert syntax_message =~ "invalid flow script"

      assert {:error, %ArgumentError{message: form_message}} =
               Script.parse("step :add, JidoTest.TestActions.Add", allowed_atoms: script_atoms())

      assert form_message =~ "expected flow name do ... end"
    end

    test "parse!/2 rejects non-atom allowed atoms" do
      assert_raise ArgumentError, ~r/allowed_atoms must contain only atoms/, fn ->
        Script.parse!("flow :scripted_combination do\nend\n", allowed_atoms: ["bad"])
      end
    end
  end
end
