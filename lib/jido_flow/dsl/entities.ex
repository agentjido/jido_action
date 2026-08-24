defmodule Jido.Flow.DSL.Step do
  @moduledoc false

  defstruct [
    :name,
    :action,
    :params,
    :__identifier__,
    __source__: %{},
    __spark_metadata__: nil,
    after: [],
    meta: %{}
  ]
end

defmodule Jido.Flow.DSL.Output do
  @moduledoc false

  defstruct [:value, :__identifier__, __source__: %{}, __spark_metadata__: nil]
end

defmodule Jido.Flow.DSL.Choice do
  @moduledoc false

  defstruct [
    :name,
    :fallback,
    :__identifier__,
    __source__: %{},
    __spark_metadata__: nil,
    options: [],
    after: [],
    meta: %{}
  ]
end

defmodule Jido.Flow.DSL.ChoiceOption do
  @moduledoc false

  defstruct [
    :name,
    :action,
    :params,
    :condition,
    :__identifier__,
    __source__: %{},
    __spark_metadata__: nil
  ]
end

defmodule Jido.Flow.DSL.Otherwise do
  @moduledoc false

  defstruct [:action, :params, :__identifier__, __source__: %{}, __spark_metadata__: nil]
end

defmodule Jido.Flow.DSL.MapNode do
  @moduledoc false

  defstruct [
    :name,
    :collection,
    :action,
    :params,
    :__identifier__,
    __source__: %{},
    __spark_metadata__: nil,
    on_error: :fail_fast,
    after: [],
    meta: %{}
  ]
end

defmodule Jido.Flow.DSL.Reduce do
  @moduledoc false

  defstruct [
    :name,
    :collection,
    :initial,
    :action,
    :params,
    :__identifier__,
    __source__: %{},
    __spark_metadata__: nil,
    after: [],
    meta: %{}
  ]
end

defmodule Jido.Flow.DSL.Iterate do
  @moduledoc false

  defstruct [
    :name,
    :state,
    :action,
    :params,
    :update,
    :while,
    :repeat,
    :max_iterations,
    :__identifier__,
    __source__: %{},
    __spark_metadata__: nil,
    after: [],
    meta: %{}
  ]
end

defmodule Jido.Flow.DSL.IterateState do
  @moduledoc false

  defstruct [:schema, :initial, :__identifier__, __source__: %{}, __spark_metadata__: nil]
end
