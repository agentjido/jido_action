defmodule Jido.Flow.DSL.Dispatch do
  @moduledoc false

  use Jido.Flow.DSL.Entity,
    node?: true,
    name: :__dispatch__,
    args: [:name, :__source__],
    identifier: :name,
    modules: [:decision, :expander],
    describe: """
    Declares a decision Action and an expander Action, in keyword or field-block
    form. Only one Dispatch is allowed. It must be the sole terminal node in the
    dependency graph, regardless of declaration order. Flow output must be its
    complete result. See [Dynamic Flows](dynamic-flows.html).
    """,
    schema: [
      name: [type: :string, required: true, doc: "The unique component name. Pass it first."],
      decision: [
        type: :atom,
        required: true,
        doc: "The Action module that receives the Dispatch parameters and returns a decision map."
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
    ]
end
