defmodule Jido.Flow.DSL.Step do
  @moduledoc false

  @type t :: %__MODULE__{
          name: term(),
          action: term(),
          params: term(),
          __identifier__: term(),
          __source__: map(),
          __spark_metadata__: term(),
          after: list(),
          meta: map()
        }

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

  @type t :: %__MODULE__{
          value: term(),
          __identifier__: term(),
          __source__: map(),
          __spark_metadata__: term()
        }

  defstruct [:value, :__identifier__, __source__: %{}, __spark_metadata__: nil]
end

defmodule Jido.Flow.DSL.Choice do
  @moduledoc false

  @type t :: %__MODULE__{
          name: term(),
          fallback: term(),
          __identifier__: term(),
          __source__: map(),
          __spark_metadata__: term(),
          options: list(),
          after: list(),
          meta: map()
        }

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

  @type t :: %__MODULE__{
          name: term(),
          action: term(),
          params: term(),
          condition: term(),
          __identifier__: term(),
          __source__: map(),
          __spark_metadata__: term()
        }

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

  @type t :: %__MODULE__{
          action: term(),
          params: term(),
          __identifier__: term(),
          __source__: map(),
          __spark_metadata__: term()
        }

  defstruct [:action, :params, :__identifier__, __source__: %{}, __spark_metadata__: nil]
end

defmodule Jido.Flow.DSL.MapNode do
  @moduledoc false

  @type t :: %__MODULE__{
          name: term(),
          collection: term(),
          action: term(),
          params: term(),
          __identifier__: term(),
          __source__: map(),
          __spark_metadata__: term(),
          on_error: term(),
          after: list(),
          meta: map()
        }

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

  @type t :: %__MODULE__{
          name: term(),
          collection: term(),
          initial: term(),
          action: term(),
          params: term(),
          __identifier__: term(),
          __source__: map(),
          __spark_metadata__: term(),
          after: list(),
          meta: map()
        }

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

  @type t :: %__MODULE__{
          name: term(),
          state: term(),
          action: term(),
          params: term(),
          update: term(),
          while: term(),
          repeat: term(),
          max_iterations: term(),
          __identifier__: term(),
          __source__: map(),
          __spark_metadata__: term(),
          after: list(),
          meta: map()
        }

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

  @type t :: %__MODULE__{
          schema: term(),
          initial: term(),
          __identifier__: term(),
          __source__: map(),
          __spark_metadata__: term()
        }

  defstruct [:schema, :initial, :__identifier__, __source__: %{}, __spark_metadata__: nil]
end

defmodule Jido.Flow.DSL.Dynamic do
  @moduledoc false

  @type t :: %__MODULE__{
          name: term(),
          decision: term(),
          expander: term(),
          params: term(),
          max_continuations: term(),
          __identifier__: term(),
          __source__: map(),
          __spark_metadata__: term(),
          after: list(),
          meta: map()
        }

  defstruct [
    :name,
    :decision,
    :expander,
    :params,
    :max_continuations,
    :__identifier__,
    __source__: %{},
    __spark_metadata__: nil,
    after: [],
    meta: %{}
  ]
end
