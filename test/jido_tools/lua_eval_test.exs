defmodule Jido.Tools.LuaEvalTest do
  use ExUnit.Case, async: true

  alias Jido.Tools.LuaEval

  @context %{}

  describe "basic execution" do
    test "executes simple arithmetic" do
      assert {:ok, %{results: [4]}} = LuaEval.run(%{code: "return 2 + 2"}, @context)
    end

    test "executes string operations" do
      assert {:ok, %{results: ["hello world"]}} =
               LuaEval.run(%{code: "return 'hello ' .. 'world'"}, @context)
    end

    test "executes multiple return values" do
      assert {:ok, %{results: [1, 2, 3]}} = LuaEval.run(%{code: "return 1, 2, 3"}, @context)
    end
  end

  describe "globals injection" do
    test "injects number globals" do
      params = %{code: "return x + 5", globals: %{"x" => 10}}
      assert {:ok, %{results: [15]}} = LuaEval.run(params, @context)
    end

    test "injects string globals" do
      params = %{code: "return greeting .. ' world'", globals: %{"greeting" => "hello"}}
      assert {:ok, %{results: ["hello world"]}} = LuaEval.run(params, @context)
    end

    test "injects atom-keyed globals" do
      params = %{code: "return x * 2", globals: %{x: 21}}
      assert {:ok, %{results: [42]}} = LuaEval.run(params, @context)
    end

    test "injects multiple globals" do
      params = %{code: "return a + b", globals: %{"a" => 10, "b" => 32}}
      assert {:ok, %{results: [42]}} = LuaEval.run(params, @context)
    end
  end

  describe "return modes" do
    test "returns first value only" do
      params = %{code: "return 1, 2, 3", return_mode: :first}
      assert {:ok, %{result: 1}} = LuaEval.run(params, @context)
    end

    test "returns list of values" do
      params = %{code: "return 1, 2, 3", return_mode: :list}
      assert {:ok, %{results: [1, 2, 3]}} = LuaEval.run(params, @context)
    end

    test "returns empty list for no return values" do
      params = %{code: "local x = 1", return_mode: :list}
      assert {:ok, %{results: []}} = LuaEval.run(params, @context)
    end

    test "returns nil for first when no return values" do
      params = %{code: "local x = 1", return_mode: :first}
      assert {:ok, %{result: nil}} = LuaEval.run(params, @context)
    end
  end

  describe "error handling" do
    test "handles compile errors" do
      assert {:error, %{type: :compile_error, message: message}} =
               LuaEval.run(%{code: "return 2 +"}, @context)

      assert is_binary(message)
    end

    test "handles runtime errors" do
      assert {:error, %{type: :lua_error, message: message}} =
               LuaEval.run(%{code: "error('boom')"}, @context)

      assert message =~ "boom"
    end

    test "handles invalid operations" do
      assert {:error, %{type: :lua_error, message: _}} =
               LuaEval.run(%{code: "return nil + 5"}, @context)
    end
  end

  describe "timeout enforcement" do
    test "enforces timeout on infinite loop" do
      params = %{code: "while true do end", timeout_ms: 50}
      assert {:error, %{type: :timeout, timeout_ms: 50}} = LuaEval.run(params, @context)
    end

    test "allows execution within timeout" do
      params = %{code: "return 42", timeout_ms: 1000}
      assert {:ok, %{results: [42]}} = LuaEval.run(params, @context)
    end
  end

  describe "sandbox security" do
    test "blocks os.getenv by default" do
      params = %{code: "return os.getenv('HOME')"}
      assert {:error, %{type: :lua_error}} = LuaEval.run(params, @context)
    end

    test "blocks require by default" do
      params = %{code: "require('os')"}
      assert {:error, %{type: :lua_error}} = LuaEval.run(params, @context)
    end

    test "allows safe math operations" do
      params = %{code: "return math.sqrt(16)"}
      assert {:ok, %{results: [4.0]}} = LuaEval.run(params, @context)
    end

    test "allows safe string operations" do
      params = %{code: "return string.upper('hello')"}
      assert {:ok, %{results: ["HELLO"]}} = LuaEval.run(params, @context)
    end

    test "allows safe table operations" do
      params = %{code: "local t = {1,2,3}; return table.concat(t, ',')"}
      assert {:ok, %{results: ["1,2,3"]}} = LuaEval.run(params, @context)
    end
  end

  describe "tool definition" do
    test "generates valid tool definition" do
      tool = LuaEval.to_tool()

      assert tool.name == "lua_eval"
      assert tool.description =~ "Execute a Lua code string"
      assert tool.parameters_schema[:required] == ["code"]

      # Verify all parameters are present
      properties = tool.parameters_schema[:properties]
      assert Map.has_key?(properties, "code")
      assert Map.has_key?(properties, "globals")
      assert Map.has_key?(properties, "return_mode")
      assert Map.has_key?(properties, "enable_unsafe_libs")
      assert Map.has_key?(properties, "timeout_ms")
      assert Map.has_key?(properties, "max_heap_bytes")
    end
  end
end
