defmodule Jido.Exec.Work do
  @moduledoc """
  A small description of one step-wise Flow work unit.

  `Jido.Exec.ready/1` returns ready work. Pass its `token` to `Jido.Exec.step/2`.
  A token selects one native unit in one execution revision. Each mutation
  invalidates all prior tokens, including tokens for work that remains ready.
  Tokens can move with the current Execution to another local process. They
  are opaque in-memory values, not native identities or storage data.

  `component_path` contains authored names without splitting names on `/`.
  It is `nil` for support work without one authored owner. `kind` is the
  component kind, or `:support` when there is no single owner. `role` identifies
  component execution, input/output work, or a support operation. A Map item
  has a zero-based `item_index`; all other work has `nil`.

  Step and wave results keep the input token and report the native unit's
  status. A failed unit is an applied transition, so it can be returned in an
  `:ok` tuple. Read the Flow result or error with `Jido.Exec.result/1`.
  Work contains no application payload, native graph, callback, or exception.
  Use `Jido.Exec.native/1` for advanced native inspection.
  """

  @typedoc "Opaque selection of one ready unit in one execution revision."
  @opaque token :: {reference(), non_neg_integer(), non_neg_integer()}

  @typedoc "Authored component kind, or support without one authored owner."
  @type kind :: :step | :subflow | :choice | :map | :reduce | :iterate | :dispatch | :support

  @typedoc "The operation of this unit. Execute keeps the component's native granularity."
  @type role ::
          :execute
          | :input
          | :output
          | :join
          | :input_binding
          | :fan_out
          | :fan_in
          | :map_item
          | :map_empty

  @typedoc "The status of this work unit, not the complete Flow."
  @type status :: :ready | :completed | :failed | :skipped

  @typedoc "A payload-free description of one native work unit."
  @type t :: %__MODULE__{
          token: token(),
          component_path: [String.t()] | nil,
          kind: kind(),
          role: role(),
          item_index: non_neg_integer() | nil,
          status: status()
        }

  @enforce_keys [:token, :component_path, :kind, :role, :item_index, :status]
  defstruct @enforce_keys

  @doc false
  @spec token(reference(), non_neg_integer(), non_neg_integer()) :: token()
  def token(execution_ref, revision, position), do: {execution_ref, revision, position}

  @doc false
  @spec position(term(), reference(), non_neg_integer()) :: {:ok, non_neg_integer()} | :error
  def position({execution_ref, revision, position}, execution_ref, revision)
      when is_integer(position) and position >= 0,
      do: {:ok, position}

  def position(_token, _execution_ref, _revision), do: :error
end
