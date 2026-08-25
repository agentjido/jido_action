defmodule Jido.Flow.Compiled do
  @moduledoc "Derived Runic compilation data for one canonical Flow."

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
          output: term(),
          source_map: source_map(),
          compilation_digest: binary()
        }

  @enforce_keys [:workflow, :component_index, :output, :source_map, :compilation_digest]
  defstruct [:workflow, :component_index, :output, :source_map, :compilation_digest]
end
