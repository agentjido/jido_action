defmodule Jido.Flow.BoundaryValidationTest do
  use ExUnit.Case, async: true

  defmodule InvalidChildFlow do
    def __jido_executable__, do: Jido.Executable.flow(__MODULE__)
    def flow, do: :invalid
    def validate_params(params), do: {:ok, params}
    def validate_output(output), do: {:ok, output}
    def run(_params, _context), do: {:ok, %{}}
  end

  defmodule RaisingChildFlow do
    def __jido_executable__, do: Jido.Executable.flow(__MODULE__)
    def flow, do: raise("child definition failed")
    def validate_params(params), do: {:ok, params}
    def validate_output(output), do: {:ok, output}
    def run(_params, _context), do: {:ok, %{}}
  end

  defmodule ThrowingChildFlow do
    def __jido_executable__, do: Jido.Executable.flow(__MODULE__)
    def flow, do: throw(:child_definition_failed)
    def validate_params(params), do: {:ok, params}
    def validate_output(output), do: {:ok, output}
    def run(_params, _context), do: {:ok, %{}}
  end

  alias Jido.Flow

  alias Jido.Flow.{
    Builder,
    Choice,
    Component,
    Data,
    Expression,
    Iterate,
    Reduce,
    Ref,
    Step
  }

  alias Jido.Flow.Map, as: FlowMap
  alias JidoActionTest.Fixtures.NestedFlow
  alias JidoActionTest.Fixtures.Actions.{Add, MissingRun}

  test "portable data rejects invalid containers, values, and keys" do
    assert {:error, _error} = Data.validate_object([])
    assert {:error, _error} = Data.validate([:ok | :tail])
    assert {:error, _error} = Data.validate(%{ok: [:good, self()]})

    for value <- [{:tuple}, fn -> :ok end, self(), make_ref(), %URI{}, hd(Port.list())] do
      assert {:error, error} = Data.validate(value)
      assert Exception.message(error) == "flow data contains an unsupported value"
    end

    for key <- [-1, nil, {:tuple}] do
      assert {:error, error} = Data.validate(%{key => :value})
      assert Exception.message(error) == "flow data contains an unsupported map key"
    end
  end

  test "Component helpers reject invalid common fields" do
    step = Step.new!(name: "step", action: Add)
    subflow = Jido.Flow.Subflow.new!(name: "child", flow: NestedFlow)
    map = FlowMap.new!(name: "map", collection: [], action: Add)

    reduce =
      Reduce.new!(name: "reduce", collection: [], initial: %{}, action: Add)

    iterate =
      Iterate.new!(
        name: "iterate",
        action: Add,
        state: [schema: [], initial: %{}, update: %{}],
        completion: Jido.Flow.Condition.eq(true, true),
        max_iterations: 1
      )

    choice =
      Choice.new!(
        name: "choice",
        options: [[name: "yes", condition: Jido.Flow.Condition.eq(true, true), action: Add]],
        fallback: [action: Add]
      )

    assert Enum.map([step, subflow, map, reduce, iterate, choice], &Component.kind/1) ==
             [:step, :subflow, :map, :reduce, :iterate, :choice]

    for component <- [step, subflow, map, reduce, iterate, choice] do
      assert {:ok, ^component} = Component.new(component)
    end

    assert {:error, _error} = Component.new(:bad)
    assert {:error, _error} = Component.name(1)
    assert {:error, _error} = Component.module(nil, "target")
    assert Component.after_names(nil) == {:ok, []}
    assert {:error, _error} = Component.after_names("step")
    assert {:error, _error} = Component.after_names(["one", "one"])
    assert Component.meta(nil) == {:ok, %{}}
    assert {:error, _error} = Component.meta(%{self() => :bad})
  end

  test "component constructors return clear boundary errors" do
    for result <- [
          FlowMap.new(:bad),
          FlowMap.new(%{name: "map", action: Add}),
          FlowMap.new(%{name: "map", collection: [], action: Add, on_error: :bad}),
          Reduce.new(:bad),
          Reduce.new(%{name: "reduce", collection: [], action: Add}),
          Iterate.new(:bad),
          Iterate.new(%{name: "iterate", action: Add}),
          Iterate.new(%{
            name: "iterate",
            action: Add,
            state: [schema: [], initial: %{}, update: %{}],
            completion: Jido.Flow.Condition.eq(true, true),
            max_iterations: 0
          })
        ] do
      assert {:error, error} = result
      assert is_exception(error)
    end

    assert_raise Jido.Flow.Error.InvalidDefinitionError, fn -> apply(FlowMap, :new!, [:bad]) end
    assert_raise Jido.Flow.Error.InvalidDefinitionError, fn -> apply(Reduce, :new!, [:bad]) end
    assert_raise Jido.Flow.Error.InvalidDefinitionError, fn -> apply(Iterate, :new!, [:bad]) end
  end

  test "Iterate state rejects incomplete and invalid authoring data" do
    assert {:ok, state} = Iterate.State.new(schema: [], initial: %{}, update: %{})
    assert Iterate.State.new(state) == {:ok, state}

    for attrs <- [
          :bad,
          [:not_keyword],
          %{schema: [], initial: %{}, update: %{}, extra: true},
          %{schema: fn -> :bad end, initial: %{}, update: %{}},
          %{schema: [], update: %{}},
          %{schema: [], initial: %{}}
        ] do
      assert {:error, %Jido.Flow.Error.InvalidDefinitionError{}} = Iterate.State.new(attrs)
    end

    assert_raise Jido.Flow.Error.InvalidDefinitionError, fn ->
      apply(Iterate.State, :new!, [:bad])
    end
  end

  test "Builder helpers converge and keep the first error" do
    assert %Ref{source: :context} = Builder.context(:request_id)
    assert %Ref{source: :item_index} = Builder.item_index()
    assert %Ref{source: :item_id} = Builder.item_id()
    assert %Ref{path: [:value]} = Builder.select(Builder.input(), :value)

    assert Enum.all?(
             [
               Builder.neq(1, 2),
               Builder.lt(1, 2),
               Builder.lte(1, 2),
               Builder.gt(2, 1),
               Builder.in(1, [1]),
               Builder.all([Builder.eq(1, 1)]),
               Builder.any([Builder.eq(1, 1)]),
               Builder.not(Builder.eq(1, 2))
             ],
             &match?(%Jido.Flow.Condition{}, &1)
           )

    option = Builder.option("yes", Builder.eq(1, 1), Add)
    fallback = Builder.fallback(Add)

    assert {:ok, %Flow{components: [_choice, _map, _reduce, _iterate]}} =
             Builder.new(name: "all_builder_components")
             |> Builder.choice("choice", [option], fallback)
             |> Builder.map("map", [], Add, %{})
             |> Builder.reduce("reduce", [], %{}, Add, %{})
             |> Builder.iterate(
               "iterate",
               Add,
               %{},
               [schema: [], initial: %{}, update: %{}],
               completion: Builder.eq(true, true),
               max_iterations: 1
             )
             |> Builder.output(%{})
             |> Builder.build()

    invalid =
      Builder.new(name: "sticky_error")
      |> Builder.step("bad", :not_an_executable, %{})
      |> Builder.step("valid_but_ignored", Add, %{})
      |> Builder.step("also_bad", Add, %{}, :not_options)

    assert {:error, %Jido.Flow.Error.InvalidDefinitionError{} = first_error} =
             Builder.build(invalid)

    assert Exception.message(first_error) =~ "executable"
    assert {:error, _error} = Builder.new([:not_keyword]) |> Builder.build()
    assert {:error, _error} = Builder.new(:bad) |> Builder.build()
  end

  test "Builder keeps constructor failures at each component boundary" do
    invalid_builders = [
      Builder.new(name: "bad_map") |> Builder.map("map", [], nil, %{}),
      Builder.new(name: "bad_reduce") |> Builder.reduce("reduce", [], %{}, nil, %{}),
      Builder.new(name: "bad_iterate") |> Builder.iterate("iterate", Add, %{}, :bad),
      Builder.new(name: "bad_choice") |> Builder.choice("choice", [], nil)
    ]

    for builder <- invalid_builders do
      assert {:error, %Jido.Flow.Error.InvalidDefinitionError{}} = Builder.build(builder)
    end
  end

  test "Flow validation rejects invalid root shapes and fields" do
    for attrs <- [
          :bad,
          %{name: 1, output: %{}},
          %{name: "flow", description: 1, output: %{}},
          %{name: "flow", schema: fn -> :bad end, output: %{}},
          %{name: "flow", components: :bad, output: %{}},
          %{name: "flow", output: nil},
          %{name: "flow", unexpected: true, output: %{}}
        ] do
      assert {:error, error} = Flow.new(attrs)
      assert is_exception(error)
    end

    duplicate = Step.new!(name: "same", action: Add)

    assert {:error, _error} =
             Flow.new(name: "duplicate", components: [duplicate, duplicate], output: %{})

    assert {:error, _error} = Flow.__validate_config__(:bad)

    invalid_target =
      Flow.new!(
        name: "invalid_target",
        components: [Step.new!(name: "missing", action: MissingRun)],
        output: Ref.result("missing")
      )

    assert {:error, _error} = Flow.validate_executable(invalid_target)

    valid_step = Step.new!(name: "step", action: Add)

    assert {:error, _error} =
             Flow.new(name: "", components: [valid_step], output: Ref.result("step"))

    assert {:ok, %Flow{schema: [], output_schema: []}} =
             Flow.new(
               name: "nil_schemas",
               schema: nil,
               output_schema: nil,
               components: [valid_step],
               output: Ref.result("step")
             )

    assert {:error, _error} = Flow.new(name: "bad_component", components: [:bad], output: %{})

    assert {:error, _error} =
             Flow.new(name: "missing_output", components: [valid_step], output: nil)
  end

  test "Flow validation contains invalid child Flow definitions" do
    for module <- [InvalidChildFlow, RaisingChildFlow, ThrowingChildFlow] do
      flow =
        Flow.new!(
          name: "invalid_child",
          components: [Jido.Flow.Subflow.new!(name: "child", flow: module)],
          output: Ref.result("child")
        )

      assert {:error, %Jido.Flow.Error.InvalidDefinitionError{}} =
               Flow.validate_executable(flow)
    end
  end

  test "Choice constructors reject incomplete and duplicate routing data" do
    condition = Jido.Flow.Condition.eq(true, true)
    valid_option = Choice.Option.new!(name: "yes", condition: condition, action: Add)
    valid_fallback = Choice.Fallback.new!(action: Add)

    assert Choice.Option.new(valid_option) == {:ok, valid_option}
    assert Choice.Fallback.new(valid_fallback) == {:ok, valid_fallback}

    for result <- [
          Choice.Option.new(:bad),
          Choice.Option.new([:not_keyword]),
          Choice.Option.new(name: "yes", action: Add),
          Choice.Option.new(name: "yes", condition: condition, action: Add, extra: true),
          Choice.Fallback.new(:bad),
          Choice.Fallback.new([:not_keyword]),
          Choice.Fallback.new(action: Add, extra: true),
          Choice.new(:bad),
          Choice.new(name: "route", options: [], fallback: valid_fallback),
          Choice.new(name: "route", options: :bad, fallback: valid_fallback),
          Choice.new(name: "route", options: [valid_option | :tail], fallback: valid_fallback),
          Choice.new(name: "route", options: [valid_option], fallback: nil),
          Choice.new(
            name: "route",
            options: [valid_option, valid_option],
            fallback: valid_fallback
          )
        ] do
      assert {:error, error} = result
      assert is_exception(error)
    end

    assert_raise Jido.Flow.Error.InvalidDefinitionError, fn ->
      apply(Choice.Option, :new!, [:bad])
    end

    assert_raise Jido.Flow.Error.InvalidDefinitionError, fn ->
      apply(Choice.Fallback, :new!, [:bad])
    end

    assert_raise Jido.Flow.Error.InvalidDefinitionError, fn -> apply(Choice, :new!, [:bad]) end

    choice =
      Choice.new!(
        name: "route",
        options: [valid_option],
        fallback: valid_fallback
      )

    assert %{kind: :choice, options: [_], fallback: %{action: Add}} = Choice.to_map(choice)
  end

  test "Expression classifies invalid refs, scope, lists, and names" do
    assert {:error, invalid_scope} = Expression.validate(Ref.item(), :flow)
    assert Expression.error_kind(invalid_scope) == :invalid_scope

    invalid_ref = %Ref{source: :unsupported, component: nil, path: []}
    assert {:error, invalid_ref_error} = Expression.validate(invalid_ref)
    assert Expression.error_kind(invalid_ref_error) == :invalid_ref

    assert {:error, improper} = Expression.validate([1 | :tail])
    assert Expression.error_kind(improper) == :improper_list
    assert {:error, _error} = Expression.normalize([Ref.result("ok") | :tail])

    assert Expression.normalize(Ref.result(:component)) ==
             {:ok, Ref.result("component")}

    assert {:error, name_error} = Expression.normalize(Ref.result(""))
    assert Expression.error_kind(name_error) == :other

    assert Expression.error_kind(%{details: %{segment: :bad}}) == :invalid_ref_path
    assert Expression.error_kind(%{details: %{expression: URI}}) == :unsupported_expression
  end
end
