defmodule Jido.Exec.Invocation do
  @moduledoc """
  Defines the host protocol for one normalized Action invocation.

  The host decides whether Exec runs the Action or reuses a receipt. Exec does
  not define storage, retry, or compatibility policy. The `compatibility`
  value is opaque host data.
  """

  @typedoc "The stable role of one Action occurrence."
  @type role :: :root_action | :step | :choice | :map | :reduce | :iterate | :dispatch

  @typedoc "The selector for one Action occurrence."
  @type selector ::
          nil
          | %{required(:kind) => :option, required(:name) => String.t()}
          | %{required(:kind) => :fallback}
          | %{required(:index) => non_neg_integer()}
          | %{required(:phase) => :decision | :expander}

  @typedoc "The portable identity of one logical Action occurrence."
  @type occurrence_id :: %{
          required(:version) => 1,
          required(:run_key) => String.t(),
          required(:chain_index) => non_neg_integer(),
          required(:component_path) => [String.t()],
          required(:role) => role(),
          required(:selector) => selector()
        }

  @typedoc "Evidence for the root or continuation executable segment."
  @type executable_evidence :: %{
          required(:kind) => :action | :flow,
          required(:form) => :module | :value,
          required(:module) => module() | nil
        }

  @typedoc "Execution evidence that the host can use for compatibility policy."
  @type evidence :: %{
          required(:executable) => executable_evidence(),
          required(:flow_semantic_digest) => binary() | nil,
          required(:compilation_digest) => binary() | nil
        }

  @typedoc "The immutable descriptor for the current Action invocation."
  @type invocation :: %{
          required(:version) => 1,
          required(:id) => occurrence_id(),
          required(:compatibility) => term(),
          required(:evidence) => evidence(),
          required(:action) => module(),
          required(:params) => map()
        }

  @typedoc "A normalized successful Action outcome."
  @type success_outcome :: %{
          required(:kind) => :ok,
          required(:output) => map() | Jido.Action.Output.t(),
          required(:effects) => [term()]
        }

  @typedoc "A normalized failed Action outcome."
  @type failure_outcome :: %{
          required(:kind) => :error,
          required(:phase) => :input | :execution | :output,
          required(:error) => Exception.t()
        }

  @typedoc "A normalized Action continuation outcome."
  @type continuation_outcome :: %{
          required(:kind) => :continue,
          required(:input) => map(),
          required(:target) => term()
        }

  @typedoc "A complete normalized Action outcome."
  @type outcome :: success_outcome() | failure_outcome() | continuation_outcome()

  @typedoc "A versioned receipt for one normalized Action outcome."
  @type receipt :: %{
          required(:version) => 1,
          required(:invocation) => invocation(),
          required(:outcome) => outcome()
        }

  @typedoc "The optional Exec invocation configuration."
  @type config :: %{
          required(:host) => module(),
          required(:ref) => term(),
          required(:run_key) => nonempty_binary(),
          required(:compatibility) => term()
        }

  @typedoc "A result from `before_invoke/2`."
  @type before_result ::
          :execute
          | {:replay, receipt()}
          | {:interrupt, term()}
          | {:error, term()}

  @typedoc "A result from `after_invoke/2`."
  @type after_result :: :ok | {:interrupt, term()} | {:error, term()}

  @doc "Chooses fresh execution, replay, or interruption before an Action invocation."
  @callback before_invoke(invocation(), ref :: term()) :: before_result()

  @doc "Accepts a fresh receipt or interrupts the complete call."
  @callback after_invoke(receipt(), ref :: term()) :: after_result()
end
