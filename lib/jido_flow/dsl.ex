defmodule Jido.Flow.DSL do
  @moduledoc false

  use Spark.Dsl,
    default_extensions: [
      extensions: [Jido.Flow.DSL.Extension]
    ]
end
