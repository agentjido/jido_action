defmodule Jido.Flow.DSL.Extension do
  @moduledoc false

  [flow] = Jido.Flow.DSL.Schema.sections()

  entities =
    Enum.map(flow.entities, fn
      %{name: :__choice__} = entity -> %{entity | imports: [Jido.Flow.DSL.ChoiceMacros]}
      %{name: :__iterate__} = entity -> %{entity | imports: [Jido.Flow.DSL.IterateMacros]}
      entity -> entity
    end)

  use Spark.Dsl.Extension,
    sections: [%{flow | imports: [Jido.Flow.DSL.Macros], entities: entities}]
end

defmodule Jido.Flow.DSL do
  @moduledoc false

  use Spark.Dsl,
    default_extensions: [
      extensions: [Jido.Flow.DSL.Extension]
    ]
end
