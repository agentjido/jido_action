defmodule Jido.Exec.FlowFailureError do
  @moduledoc """
  Reports two or more runnable failures from one Flow wave.

  A wave can finish with more than one failure because its runnables were
  already selected. The `failures` field keeps the errors in apply order.
  """

  @typedoc "A failed native runnable and its original error."
  @type failure :: %{node: term(), runnable_id: integer(), error: Exception.t()}

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
      message: "Flow #{inspect(flow)} failed in #{length(failures)} runnables",
      flow: flow,
      failures: failures
    }
  end
end
