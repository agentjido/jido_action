defmodule Jido.Tools.Github.HelpersTest do
  use JidoTest.ActionCase, async: true

  alias Jido.Tools.Github.Helpers

  describe "client/2" do
    test "prefers params client over context sources" do
      params = %{client: :params_client}
      context = %{client: :context_client, tool_context: %{client: :tool_context_client}}

      assert Helpers.client(params, context) == :params_client
    end

    test "falls back to context client" do
      params = %{}
      context = %{client: :context_client, tool_context: %{client: :tool_context_client}}

      assert Helpers.client(params, context) == :context_client
    end

    test "falls back to tool_context client" do
      params = %{}
      context = %{tool_context: %{client: :tool_context_client}}

      assert Helpers.client(params, context) == :tool_context_client
    end
  end

  describe "success/1" do
    test "wraps result in the standard success response shape" do
      payload = %{"id" => 1}

      assert Helpers.success(payload) ==
               {:ok, %{status: "success", data: payload, raw: payload}}
    end
  end

  describe "compact_nil/1" do
    test "removes nil values" do
      input = %{a: 1, b: nil, c: "value"}

      assert Helpers.compact_nil(input) == %{a: 1, c: "value"}
    end
  end

  describe "compact_blank/1" do
    test "removes nil and empty-string values" do
      input = %{a: 1, b: nil, c: "", d: "value"}

      assert Helpers.compact_blank(input) == %{a: 1, d: "value"}
    end
  end

  describe "maybe_put/3" do
    test "does not set key when value is nil" do
      assert Helpers.maybe_put(%{"a" => 1}, "b", nil) == %{"a" => 1}
    end

    test "sets key when value is present" do
      assert Helpers.maybe_put(%{"a" => 1}, "b", 2) == %{"a" => 1, "b" => 2}
    end
  end
end
