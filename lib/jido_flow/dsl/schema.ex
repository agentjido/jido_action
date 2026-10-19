defmodule Jido.Flow.DSL.Schema do
  @moduledoc false

  alias Jido.Flow.DSL.{Choice, Dispatch, Iterate, MapNode, Output, Reduce, Step}

  @flow %Spark.Dsl.Section{
    name: :flow,
    describe: "Declares a Jido Flow graph.",
    entities: [
      Step.entity(),
      Jido.Flow.DSL.Timer.entity(),
      Jido.Flow.DSL.Await.entity(),
      Jido.Flow.DSL.Selection.entity(),
      Choice.entity(),
      MapNode.entity(),
      Reduce.entity(),
      Iterate.entity(),
      Dispatch.entity(),
      Output.entity()
    ],
    singleton_entity_keys: [:output]
  }

  @doc false
  @spec sections() :: [Spark.Dsl.Section.t()]
  def sections, do: [@flow]
end
