defmodule Jido.Exec.WaitStore do
  @moduledoc """
  Store contract for host-owned, serialized Flow wait transitions.

  Save a native Runic snapshot with compare-and-swap before acknowledging input.
  Retrying the same successful save after a lost reply must return its existing
  revision. A different stale save must fail with `:conflict`. Hosts reload and
  resolve uncertain replies before they retry work. The adapter owns retention,
  transactions, ownership, and durability; this contract adds no checkpoint format.
  """
  @typedoc "A monotonically increasing store revision. A missing execution has revision zero."
  @type revision :: non_neg_integer()

  @doc "Loads the last acknowledged native Runic workflow and its revision."
  @callback load(term(), term()) :: {:ok, revision(), Runic.Workflow.t()} | {:error, term()}

  @doc "Atomically saves a revision, or acknowledges an equal retry after a lost reply."
  @callback save(term(), revision(), Runic.Workflow.t(), term()) ::
              {:ok, revision()} | {:error, term()}
end
