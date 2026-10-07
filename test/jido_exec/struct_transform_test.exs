defmodule JidoActionTest.Exec.StructTransformTest do
  use ExUnit.Case, async: true

  alias Jido.Exec
  alias Jido.Action.Validation
  alias Jido.Flow.{Ref}

  defmodule Input do
    defstruct [:value, derived: :undeclared_default]
  end

  defmodule Output do
    defstruct [:renamed, :derived]
  end

  defmodule Effects do
    def schema(transform) do
      base_schema() |> Zoi.transform({__MODULE__, transform, []})
    end

    def base_schema, do: Zoi.struct(Input, %{value: Zoi.integer()}, coerce: true)
    def same(%Input{value: value} = input, _opts), do: %{input | derived: value * 2}
    def different(%Input{value: value}, _opts), do: %Output{renamed: value, derived: value * 2}
    def refine(%Input{}, _opts), do: :ok
  end

  defmodule Echo do
    use Jido.Action, name: "struct_transform_echo"
    def run(params, _context), do: {:ok, params}
  end

  defmodule SameInputAction do
    use Jido.Action, name: "same_struct_input", schema: Effects.schema(:same)
    def run(params, _context), do: {:ok, params}
  end

  defmodule DifferentInputAction do
    use Jido.Action, name: "different_struct_input", schema: Effects.schema(:different)
    def run(params, _context), do: {:ok, params}
  end

  defmodule SameOutputAction do
    use Jido.Action, name: "same_struct_output", output_schema: Effects.schema(:same)
    def run(params, _context), do: {:ok, params}
  end

  defmodule DifferentOutputAction do
    use Jido.Action,
      name: "different_struct_output",
      output_schema: Effects.schema(:different)

    def run(params, _context), do: {:ok, params}
  end

  defmodule SameInputFlow do
    use Jido.Flow, name: "same_struct_input_flow", schema: Effects.schema(:same)

    flow do
      step "echo", action: Echo, params: input()
      output result("echo")
    end
  end

  defmodule DifferentInputFlow do
    use Jido.Flow, name: "different_struct_input_flow", schema: Effects.schema(:different)

    flow do
      step "echo", action: Echo, params: input()
      output result("echo")
    end
  end

  defmodule SameOutputFlow do
    use Jido.Flow, name: "same_struct_output_flow", output_schema: Effects.schema(:same)

    flow do
      step "echo", action: Echo, params: input()
      output result("echo")
    end
  end

  defmodule DifferentOutputFlow do
    use Jido.Flow,
      name: "different_struct_output_flow",
      output_schema: Effects.schema(:different)

    flow do
      step "echo", action: Echo, params: input()
      output result("echo")
    end
  end

  for {label, action, flow, field, callback, expected} <- [
        {"same struct input", SameInputAction, SameInputFlow, :schema, :validate_params,
         %{value: 3, derived: 6, request_tag: :kept}},
        {"different struct input", DifferentInputAction, DifferentInputFlow, :schema,
         :validate_params, %{renamed: 3, derived: 6, request_tag: :kept}},
        {"same struct output", SameOutputAction, SameOutputFlow, :output_schema, :validate_output,
         %{value: 3, derived: 6, request_tag: :kept}},
        {"different struct output", DifferentOutputAction, DifferentOutputFlow, :output_schema,
         :validate_output, %{renamed: 3, derived: 6, request_tag: :kept}}
      ] do
    @action action
    @flow flow
    @field field
    @validation_callback callback
    @expected expected

    test "#{label} retains transformed fields in direct and Step Actions" do
      input = %{value: 3, request_tag: :kept}

      assert apply(@action, @validation_callback, [input]) == {:ok, @expected}
      assert Exec.run(@action, input) == {:ok, @expected}
      assert Exec.run(action_flow(@action), input) == {:ok, @expected}
    end

    test "#{label} retains transformed fields in data, generated, and nested Flows" do
      input = %{value: 3, request_tag: :kept}
      runtime = action_flow(Echo, [{@field, apply(@action, @field, [])}])

      for target <- [runtime, @flow] do
        assert Exec.run(target, input) == {:ok, @expected}
      end

      parent =
        JidoActionTest.FlowBuilder.new!(
          name: "nested_struct_transform",
          components: [
            JidoActionTest.FlowComponent.subflow!(
              name: "child",
              flow: @flow,
              params: Ref.input([])
            )
          ],
          output: Ref.result("child")
        )

      assert Exec.run(parent, input) == {:ok, @expected}
    end
  end

  test "ordinary and refinement-only Struct schemas omit undeclared defaults" do
    base = Effects.base_schema()
    refined = Zoi.refine(base, {Effects, :refine, []})

    for schema <- [base, refined],
        input <- [%{value: 3}, %{value: 3, derived: :from_input, request_tag: :kept}] do
      assert Validation.open_validate(schema, input, %{}) == {:ok, input}
    end
  end

  test "shape-preserving validation retains transformed structs" do
    assert Validation.open_validate_preserving_shape(Effects.schema(:same), %{value: 3}, %{}) ==
             {:ok, %Input{value: 3, derived: 6}}

    assert Validation.open_validate_preserving_shape(Effects.schema(:different), %{value: 3}, %{}) ==
             {:ok, %Output{renamed: 3, derived: 6}}
  end

  defp action_flow(action, options \\ []) do
    [
      name: "struct_transform",
      components: [
        JidoActionTest.FlowComponent.step!(name: "echo", action: action, params: Ref.input([]))
      ],
      output: Ref.result("echo")
    ]
    |> Keyword.merge(options)
    |> JidoActionTest.FlowBuilder.new!()
  end
end
