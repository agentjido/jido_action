defmodule Jido.Flow.DSL.Extension do
  @moduledoc false

  @node_fields [
    __source__: [
      type: :map,
      default: %{}
    ],
    needs: [
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
    describe: """
    Declares one Action call, or a Subflow when the target is a Flow module.
    These fields describe module-backed Steps, in keyword or field-block form.
    Direct inline bodies use bindings instead of `action` and `params`; put
    Action settings in `inline:` and keep `needs` and `meta` at Step level.
    See [Steps And Output](flow-steps.html) and [Inline Actions](inline-actions.html).
    """,
    schema:
      [
        name: [type: :string, required: true, doc: "The unique Step name. Pass it first."],
        action: [type: :atom, required: true, doc: "The Action or Flow module to call."],
        params: [
          type: :quoted,
          required: true,
          doc: "An expression that supplies the target parameters."
        ]
      ] ++ @node_fields
  }

  @choice_option %Spark.Dsl.Entity{
    name: :__option__,
    target: Jido.Flow.DSL.ChoiceOption,
    args: [:name, :__source__],
    identifier: :name,
    modules: [:action],
    describe:
      "Declares one named Choice option, in keyword or field-block form. Only the first matching option runs.",
    schema: [
      name: [
        type: :string,
        required: true,
        doc: "The unique option name within this Choice. Pass it first."
      ],
      action: [
        type: :atom,
        required: true,
        doc: "The Action module to call when this option matches."
      ],
      params: [
        type: :quoted,
        required: true,
        doc: "An expression that supplies the selected Action parameters."
      ],
      condition: [
        type: :quoted,
        required: true,
        doc: "A Boolean Flow expression, tested in option declaration order."
      ],
      __source__: [type: :map, default: %{}]
    ]
  }

  @otherwise %Spark.Dsl.Entity{
    name: :__otherwise__,
    target: Jido.Flow.DSL.Otherwise,
    args: [:__source__],
    modules: [:action],
    describe:
      "Declares the required unnamed fallback, in keyword or field-block form. It runs when no option matches, not when a selected Action fails.",
    schema: [
      action: [
        type: :atom,
        required: true,
        doc: "The Action module to call when no option matches."
      ],
      params: [
        type: :quoted,
        required: true,
        doc: "An expression that supplies the fallback parameters."
      ],
      __source__: [type: :map, default: %{}]
    ]
  }

  @choice %Spark.Dsl.Entity{
    name: :__choice__,
    target: Jido.Flow.DSL.Choice,
    args: [:name, :__source__],
    identifier: :name,
    describe: """
    Declares ordered options and exactly one `otherwise` fallback in a block.
    Result references in all targets create dependencies, even in unselected
    options. See [Choices And Conditions](flow-choices.html).
    """,
    schema:
      [name: [type: :string, required: true, doc: "The unique component name. Pass it first."]] ++
        @node_fields,
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
    describe:
      "Runs one Action for each collection item, preserving input order. Use keyword or field-block form. See [Map And Reduce](flow-collections.html).",
    schema:
      [
        name: [
          type: :string,
          required: true,
          doc: "The unique component name. Pass it as the first positional argument."
        ],
        collection: [
          type: :quoted,
          required: true,
          doc: "An expression that resolves to the list of items to process."
        ],
        action: [
          type: :atom,
          required: true,
          doc: "The Action module to call for each item. Inline bodies are not supported."
        ],
        params: [
          type: :quoted,
          required: true,
          doc: "The parameter expression for each call. Use `item()` to read the current item."
        ],
        on_error: [
          type: {:one_of, [:fail_fast, :collect_errors]},
          default: :fail_fast,
          doc:
            "Stop on an item error, or return a success or error record for each item in input order."
        ]
      ] ++ @node_fields
  }

  @reduce %Spark.Dsl.Entity{
    name: :__reduce__,
    target: Jido.Flow.DSL.Reduce,
    args: [:name, :__source__],
    identifier: :name,
    modules: [:action],
    describe:
      "Folds a list serially through one Action, in keyword or field-block form. An empty list returns the initial accumulator. See [Map And Reduce](flow-collections.html).",
    schema:
      [
        name: [type: :string, required: true, doc: "The unique component name. Pass it first."],
        collection: [
          type: :quoted,
          required: true,
          doc: "An expression that resolves to the list to fold."
        ],
        initial: [type: :quoted, required: true, doc: "The initial accumulator expression."],
        action: [
          type: :atom,
          required: true,
          doc: "The Action module to call for each item. Its result becomes the next accumulator."
        ],
        params: [
          type: :quoted,
          required: true,
          doc: "The call parameter expression. Use `item()` and `accumulator()` for local values."
        ]
      ] ++ @node_fields
  }

  @iterate_state %Spark.Dsl.Entity{
    name: :__state__,
    target: Jido.Flow.DSL.IterateState,
    args: [:schema, :__source__],
    modules: [:schema],
    describe:
      "Declares the required Iterate state, in keyword or field-block form. The schema validates the initial value and every replacement. State is replaced, not merged.",
    schema: [
      schema: [
        type: :any,
        required: true,
        doc: "The static State schema, or `[]`. Pass it first."
      ],
      initial: [
        type: :quoted,
        required: true,
        doc: "An expression that supplies the initial State."
      ],
      __source__: [type: :map, default: %{}]
    ]
  }

  @iterate %Spark.Dsl.Entity{
    name: :__iterate__,
    target: Jido.Flow.DSL.Iterate,
    args: [:name, :__source__],
    identifier: :name,
    modules: [:action],
    describe: """
    Declares one required `state` and an Action body in a field block.
    Choose exactly one termination form: `repeat`, without `max_iterations`,
    or `while` with `max_iterations`. The condition is checked before each call;
    if it remains true at the bound, execution fails.
    See [Iterate And State](flow-iterate-state.html).
    """,
    schema:
      [
        name: [type: :string, required: true, doc: "The unique component name. Pass it first."],
        action: [
          type: :atom,
          required: true,
          doc:
            "The Action module for the loop body. Flow targets and inline bodies are not supported."
        ],
        params: [
          type: :quoted,
          required: true,
          doc:
            "The body parameter expression. Use `state()` and `iteration_index()` for local values."
        ],
        update: [
          type: :quoted,
          doc:
            "The replacement State expression after each successful call. If omitted, Jido uses the complete `body_result()` instead."
        ],
        while: [
          type: :quoted,
          doc:
            "A Boolean head condition. Requires `max_iterations`; cannot be combined with `repeat`."
        ],
        repeat: [
          type: :pos_integer,
          doc:
            "A fixed count from 1 through 10,000. Cannot be combined with `while` or `max_iterations`."
        ],
        max_iterations: [
          type: :pos_integer,
          doc:
            "The bound from 1 through 10,000 for a `while` loop. Required with `while` and forbidden with `repeat`."
        ]
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
    describe: """
    Declares a decision Action and an expander Action, in keyword or field-block
    form. Only one Dispatch is allowed. It must be the sole terminal node in the
    dependency graph, regardless of declaration order. Flow output must be its
    complete result. See [Dynamic Flows](dynamic-flows.html).
    """,
    schema:
      [
        name: [type: :string, required: true, doc: "The unique component name. Pass it first."],
        decision: [
          type: :atom,
          required: true,
          doc:
            "The Action module that receives the Dispatch parameters and returns a decision map."
        ],
        expander: [
          type: :atom,
          required: true,
          doc:
            "The Action module that receives the complete decision map. It can return a final result or a continuation."
        ],
        params: [
          type: :quoted,
          required: true,
          doc: "An expression that supplies the decision Action parameters."
        ]
      ] ++ @node_fields
  }

  @output %Spark.Dsl.Entity{
    name: :__output__,
    target: Jido.Flow.DSL.Output,
    args: [:value, :__source__],
    describe:
      "Declares the required, non-nil Flow output. Pass the value as the only argument; there is no field-block form. Output must be the final declaration. See [Steps And Output](flow-steps.html).",
    schema: [
      value: [
        type: :quoted,
        required: true,
        doc: "The Flow result expression. Pass it directly to `output`, not as a keyword field."
      ],
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
