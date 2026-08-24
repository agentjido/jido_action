defmodule Jido.Exec.FlowFailureError do
  @moduledoc """
  Reports two or more node failures from one concurrent Flow wave.

  A serial Flow stops when its first node fails. A concurrent wave can finish
  with more than one failure because its nodes are already in progress. The
  `failures` field keeps all such failures in canonical node order.
  """

  @typedoc "A failed node and its original error."
  @type failure :: %{node: String.t(), error: Exception.t()}

  @type t :: %__MODULE__{
          message: String.t(),
          flow: String.t(),
          failures: [failure()]
        }

  @enforce_keys [:flow, :failures]
  defexception [:message, :flow, :failures]

  @impl Exception
  def exception(opts) do
    flow = Keyword.fetch!(opts, :flow)
    failures = Keyword.fetch!(opts, :failures)

    %__MODULE__{
      message: "Flow #{inspect(flow)} failed in #{length(failures)} concurrent nodes",
      flow: flow,
      failures: failures
    }
  end
end
