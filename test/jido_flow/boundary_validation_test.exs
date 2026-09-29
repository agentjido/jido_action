defmodule Jido.Flow.BoundaryValidationTest do
  use ExUnit.Case, async: true

  defmodule InvalidChildFlow do
    def __jido_executable__ do
      Jido.Executable.flow(__MODULE__)
    end

    def flow do
      :invalid
    end

    def validate_params(params) do
      {:ok, params}
    end

    def validate_output(output) do
      {:ok, output}
    end

    def run(_params, _context) do
      {:ok, %{}}
    end
  end

  defmodule RaisingChildFlow do
    def __jido_executable__ do
      Jido.Executable.flow(__MODULE__)
    end

    def flow do
      raise "child definition failed"
    end

    def validate_params(params) do
      {:ok, params}
    end

    def validate_output(output) do
      {:ok, output}
    end

    def run(_params, _context) do
      {:ok, %{}}
    end
  end

  defmodule ThrowingChildFlow do
    def __jido_executable__ do
      Jido.Executable.flow(__MODULE__)
    end

    def flow do
      throw(:child_definition_failed)
    end

    def validate_params(params) do
      {:ok, params}
    end

    def validate_output(output) do
      {:ok, output}
    end

    def run(_params, _context) do
      {:ok, %{}}
    end
  end

  alias Jido.Flow
  alias Jido.Flow.{Choice, Component, Data, Expression, Iterate, Reduce, Ref, Step}
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

  test "portable data keeps nested error paths and rejects improper lists first" do
    for {value, message, path} <- [
          {%{outer: [0, %{inner: self()}]}, "flow data contains an unsupported value",
           [:outer, 1, :inner]},
          {%{outer: [0, %{nil: :value}]}, "flow data contains an unsupported map key",
           [:outer, 1]},
          {%{outer: [0, <<255>>]}, "flow data strings must be valid UTF-8", [:outer, 1]},
          {%{outer: [0, %{<<255>> => :value}]}, "flow data strings must be valid UTF-8",
           [:outer, 1]},
          {%{outer: [[self() | :tail]]}, "flow data must contain proper lists", [:outer, 0]}
        ] do
      assert {:error, error} = Data.validate(value)
      assert error.message == message
      assert error.details.path == path
    end
  end

  test "Component helpers reject invalid common fields" do
    step = Step.new!(name: "step", action: Add)
    subflow = Jido.Flow.Subflow.new!(name: "child", flow: NestedFlow)
    map = FlowMap.new!(name: "map", collection: [], action: Add)
    reduce = Reduce.new!(name: "reduce", collection: [], initial: %{}, action: Add)

    iterate =
      Iterate.new!(
        name: "iterate",
        action: Add,
        state: [schema: [], initial: %{}, update: %{}],
        completion: Jido.Expr.new!(:eq, [true, true]),
        max_iterations: 1
      )

    choice =
      Choice.new!(
        name: "choice",
        options: [[name: "yes", condition: Jido.Expr.new!(:eq, [true, true]), action: Add]],
        fallback: [action: Add]
      )

    assert Enum.map([step, subflow, map, reduce, iterate, choice], &Component.kind/1) == [
             :step,
             :subflow,
             :map,
             :reduce,
             :iterate,
             :choice
           ]

    for component <- [step, subflow, map, reduce, iterate, choice] do
      assert {:ok, ^component} = Component.new(component)
    end

    assert {:error, _error} = Component.new(:bad)
    assert {:error, _error} = Component.name(1)
    assert {:error, _error} = Component.module(nil, "target")
    assert Component.needs_names(nil) == {:ok, []}
    assert {:error, _error} = Component.needs_names("step")
    assert {:error, _error} = Component.needs_names(["one", "one"])
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
            completion: Jido.Expr.new!(:eq, [true, true]),
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

  test "reference helpers and map definitions use canonical constructors" do
    assert %Ref{source: :context} = Jido.Flow.Ref.context(:request_id)
    assert %Ref{source: :item_index} = Jido.Flow.Ref.item_index()
    assert %Ref{source: :item_id} = Jido.Flow.Ref.item_id()
    assert %Ref{path: [:value]} = Jido.Flow.Ref.select(Jido.Flow.Ref.input([]), :value)

    assert Enum.all?(
             [
               Jido.Expr.new!(:neq, [1, 2]),
               Jido.Expr.new!(:lt, [1, 2]),
               Jido.Expr.new!(:lte, [1, 2]),
               Jido.Expr.new!(:gt, [2, 1]),
               Jido.Expr.new!(:in, [1, [1]]),
               Jido.Expr.new!(:all, [Jido.Expr.new!(:eq, [1, 1])]),
               Jido.Expr.new!(:any, [Jido.Expr.new!(:eq, [1, 1])]),
               Jido.Expr.new!(:not, [Jido.Expr.new!(:eq, [1, 2])])
             ],
             &match?(%Jido.Expr{}, &1)
           )

    option = %{name: "yes", condition: Jido.Expr.new!(:eq, [1, 1]), action: Add, params: %{}}
    fallback = %{action: Add, params: %{}}

    assert {:ok, %Flow{components: [_choice, _map, _reduce, _iterate]}} =
             Jido.Flow.new(%{
               output: %{},
               components: [
                 %{kind: :choice, name: "choice", options: [option], fallback: fallback},
                 %{kind: :map, name: "map", collection: [], action: Add, params: %{}},
                 %{
                   kind: :reduce,
                   name: "reduce",
                   collection: [],
                   initial: %{},
                   action: Add,
                   params: %{}
                 },
                 %{
                   kind: :iterate,
                   name: "iterate",
                   action: Add,
                   params: %{},
                   state: [schema: [], initial: %{}, update: %{}],
                   completion: Jido.Expr.new!(:eq, [true, true]),
                   max_iterations: 1
                 }
               ],
               name: "all_data_components"
             })

    assert {:error, %Jido.Flow.Error.InvalidDefinitionError{}} =
             Flow.new(%{
               name: "invalid",
               components: [%{kind: :step, name: "bad", action: nil}],
               output: %{}
             })

    assert {:error, _error} = Flow.new([:not_keyword])
    assert {:error, _error} = Flow.new(:bad)
  end

  test "map definitions return constructor failures at each component boundary" do
    invalid_definitions = [
      %{
        components: [%{kind: :map, name: "map", collection: [], action: nil, params: %{}}],
        name: "bad_map"
      },
      %{
        components: [
          %{kind: :reduce, name: "reduce", collection: [], initial: %{}, action: nil, params: %{}}
        ],
        name: "bad_reduce"
      },
      %{
        components: [%{kind: :iterate, name: "iterate", action: Add, params: %{}, state: :bad}],
        name: "bad_iterate"
      },
      %{
        components: [%{kind: :choice, name: "choice", options: [], fallback: nil}],
        name: "bad_choice"
      }
    ]

    for data <- invalid_definitions do
      assert {:error, %Jido.Flow.Error.InvalidDefinitionError{}} = Jido.Flow.new(data)
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

      assert {:error, %Jido.Flow.Error.InvalidDefinitionError{}} = Flow.validate_executable(flow)
    end
  end

  test "Choice constructors reject incomplete and duplicate routing data" do
    condition = Jido.Expr.new!(:eq, [true, true])
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
    choice = Choice.new!(name: "route", options: [valid_option], fallback: valid_fallback)
    assert %{kind: :choice, options: [_], fallback: %{action: Add}} = Choice.to_map(choice)
  end

  test "Expression rejects invalid refs, scope, lists, and names" do
    assert {:error, invalid_scope} = Expression.validate(Ref.item(), :flow)
    assert invalid_scope.details == %{path: [], ref_type: :item, scope: :flow}
    invalid_ref = %Ref{source: :unsupported, component: nil, path: []}
    assert {:error, invalid_ref_error} = Expression.validate(invalid_ref)
    assert invalid_ref_error.details == %{path: [], ref_type: :unsupported}
    assert {:error, improper} = Expression.validate([1 | :tail])
    assert improper.details.reason == :improper_list
    assert {:error, _error} = Expression.normalize([Ref.result("ok") | :tail])
    atom_result_ref = %Ref{source: :result, component: :component, path: []}
    assert Expression.normalize(atom_result_ref) == {:ok, Ref.result("component")}
    assert {:error, name_error} = Expression.normalize(Ref.result(""))
    assert Exception.message(name_error) == "Action name cannot be blank."
  end

  test "Expression preserves nested validation and normalization errors" do
    assert {:error, scoped_error} = Expression.validate([Ref.item()], :flow)
    assert scoped_error.details == %{path: [0], ref_type: :item, scope: :flow}
    invalid_result_ref = %Ref{source: :result, component: "", path: []}
    assert {:error, normalization_error} = Expression.normalize([%{result: invalid_result_ref}])
    assert Exception.message(normalization_error) == "Action name cannot be blank."
  end
end
