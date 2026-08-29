defmodule Jido.Flow.DSL.Extension do
  @moduledoc false

  @node_fields [
    __source__: [
      type: :map,
      default: %{}
    ],
    after: [
      type: {:wrap_list, :string},
      default: [],
      doc: "Explicit control dependencies."
    ],
    meta: [
      type: :map,
      default: %{},
      doc: "Non-semantic node metadata."
    ]
  ]

  @step %Spark.Dsl.Entity{
    name: :__step__,
    target: Jido.Flow.DSL.Step,
    args: [:name, :__source__],
    identifier: :name,
    modules: [:action],
    describe: "Declares one named Action call.",
    schema:
      [
        name: [type: :string, required: true],
        action: [type: :atom, required: true],
        params: [type: :quoted, required: true]
      ] ++ @node_fields
  }

  @choice_option %Spark.Dsl.Entity{
    name: :__option__,
    target: Jido.Flow.DSL.ChoiceOption,
    args: [:name, :__source__],
    identifier: :name,
    modules: [:action],
    describe: "Declares one ordered Choice target.",
    schema: [
      name: [type: :string, required: true],
      action: [type: :atom, required: true],
      params: [type: :quoted, required: true],
      condition: [type: :quoted, required: true],
      __source__: [type: :map, default: %{}]
    ]
  }

  @otherwise %Spark.Dsl.Entity{
    name: :__otherwise__,
    target: Jido.Flow.DSL.Otherwise,
    args: [:__source__],
    modules: [:action],
    describe: "Declares the required Choice fallback target.",
    schema: [
      action: [type: :atom, required: true],
      params: [type: :quoted, required: true],
      __source__: [type: :map, default: %{}]
    ]
  }

  @choice %Spark.Dsl.Entity{
    name: :__choice__,
    target: Jido.Flow.DSL.Choice,
    args: [:name, :__source__],
    identifier: :name,
    describe: "Declares one ordered Action selection.",
    schema: [name: [type: :string, required: true]] ++ @node_fields,
    imports: [Jido.Flow.DSL.ChoiceMacros],
    entities: [options: [@choice_option], fallback: [@otherwise]],
    singleton_entity_keys: [:fallback]
  }

  @map %Spark.Dsl.Entity{
    name: :__map__,
    target: Jido.Flow.DSL.MapNode,
    args: [:name, :__source__],
    identifier: :name,
    modules: [:action],
    describe: "Runs one Action for each collection item.",
    schema:
      [
        name: [type: :string, required: true],
        collection: [type: :quoted, required: true],
        action: [type: :atom, required: true],
        params: [type: :quoted, required: true],
        on_error: [type: {:one_of, [:fail_fast, :collect_errors]}, default: :fail_fast]
      ] ++ @node_fields
  }

  @reduce %Spark.Dsl.Entity{
    name: :__reduce__,
    target: Jido.Flow.DSL.Reduce,
    args: [:name, :__source__],
    identifier: :name,
    modules: [:action],
    describe: "Folds a collection through one Action.",
    schema:
      [
        name: [type: :string, required: true],
        collection: [type: :quoted, required: true],
        initial: [type: :quoted, required: true],
        action: [type: :atom, required: true],
        params: [type: :quoted, required: true]
      ] ++ @node_fields
  }

  @iterate_state %Spark.Dsl.Entity{
    name: :__state__,
    target: Jido.Flow.DSL.IterateState,
    args: [:schema, :__source__],
    modules: [:schema],
    describe: "Declares the Iterate state contract and initial value.",
    schema: [
      schema: [type: :any, required: true],
      initial: [type: :quoted, required: true],
      __source__: [type: :map, default: %{}]
    ]
  }

  @iterate %Spark.Dsl.Entity{
    name: :__iterate__,
    target: Jido.Flow.DSL.Iterate,
    args: [:name, :__source__],
    identifier: :name,
    modules: [:action],
    describe: "Declares bounded repeated state transitions.",
    schema:
      [
        name: [type: :string, required: true],
        action: [type: :atom, required: true],
        params: [type: :quoted, required: true],
        update: [type: :quoted],
        while: [type: :quoted],
        repeat: [type: :pos_integer],
        max_iterations: [type: :pos_integer]
      ] ++ @node_fields,
    imports: [Jido.Flow.DSL.IterateMacros],
    entities: [state: [@iterate_state]],
    singleton_entity_keys: [:state]
  }

  @dispatch %Spark.Dsl.Entity{
    name: :__dispatch__,
    target: Jido.Flow.DSL.Dispatch,
    args: [:name, :__source__],
    identifier: :name,
    modules: [:decision, :expander],
    describe: "Declares one component that can choose what runs next.",
    schema:
      [
        name: [type: :string, required: true],
        decision: [type: :atom, required: true],
        expander: [type: :atom, required: true],
        params: [type: :quoted, required: true]
      ] ++ @node_fields
  }

  @output %Spark.Dsl.Entity{
    name: :__output__,
    target: Jido.Flow.DSL.Output,
    args: [:value, :__source__],
    describe: "Declares the Flow output expression.",
    schema: [
      value: [type: :quoted, required: true],
      __source__: [type: :map, default: %{}]
    ]
  }

  @flow %Spark.Dsl.Section{
    name: :flow,
    describe: "Declares a Jido Flow graph.",
    imports: [Jido.Flow.DSL.Macros],
    entities: [@step, @choice, @map, @reduce, @iterate, @dispatch, @output],
    singleton_entity_keys: [:output]
  }

  use Spark.Dsl.Extension, sections: [@flow]
end

defmodule Jido.Flow.DSL do
  @moduledoc false

  use Spark.Dsl,
    default_extensions: [
      extensions: [Jido.Flow.DSL.Extension]
    ]
end
