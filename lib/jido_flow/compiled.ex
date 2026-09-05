defmodule Jido.Flow.Compiled do
  @moduledoc """
  Derived Runic compilation data for one canonical Flow.

  Use `Jido.Flow.compile/2` to create this value. The `workflow` field is the
  native `Runic.Workflow`. The other fields connect authored components,
  source locations, output data, and deterministic compilation identity to
  that workflow. `work_index` is internal compiler metadata for step-wise
  descriptions. This value is not authoring or stored data.
  """

  @type source_path :: [String.t() | atom() | non_neg_integer()]
  @type source_location :: %{
          optional(:file) => String.t(),
          optional(:line) => pos_integer(),
          optional(:column) => pos_integer()
        }
  @type source_map :: %{optional(source_path()) => source_location()}

  @type t :: %__MODULE__{
          workflow: Runic.Workflow.t(),
          component_index: map(),
          work_index: map(),
          output: Jido.Flow.Expression.t(),
          source_map: source_map(),
          compilation_digest: binary()
        }

  @enforce_keys [:workflow, :component_index, :output, :source_map, :compilation_digest]
  defstruct [
    :workflow,
    :component_index,
    :output,
    :source_map,
    :compilation_digest,
    work_index: %{}
  ]
end
