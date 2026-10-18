defmodule Jido.Exec.Test.WaitStore do
  @moduledoc false

  @typedoc "A monotonically increasing store revision. A missing execution has revision zero."
  @type revision :: non_neg_integer()

  @doc "Loads the last acknowledged native Runic workflow and its revision."
  @callback load(term(), term()) :: {:ok, revision(), Runic.Workflow.t()} | {:error, term()}

  @doc "Atomically saves a revision, or acknowledges an equal retry after a lost reply."
  @callback save(term(), revision(), Runic.Workflow.t(), term()) ::
              {:ok, revision()} | {:error, term()}
end
