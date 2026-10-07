defmodule Jido.Exec.Invocation do
  @moduledoc """
  Defines the optional host protocol for one normalized Action invocation.

  Pass an invocation configuration to `Jido.Exec.run/4` or
  `Jido.Exec.run_async/4`:

      %{
        host: MyApp.InvocationHost,
        ref: host_ref,
        run_key: "order-123",
        compatibility: %{release: "2026-10"}
      }

  Exec calls `c:before_invoke/2` before input validation, the Action callback,
  and output validation. The host can allow that work, return a prior receipt,
  or interrupt the complete call. After fresh work, Exec calls
  `c:after_invoke/2` with the complete normalized receipt. The fresh result
  cannot reach Flow work or the root caller until the host returns `:ok`.

  Replay starts a new Exec call. Exec runs Flow orchestration again and uses a
  host-approved receipt in place of the Action work. A replay skips Action
  input validation, the Action callback, Action output validation, and the
  after callback. Exec checks the receipt version, exact occurrence key, and
  normalized outcome shape. The host decides if the compatibility token,
  Action, parameters, and execution evidence permit reuse.

  The descriptor does not contain raw context. Its `params` field contains the
  resolved parameters before Action input validation. If Flow bindings copy a
  context value into parameters, that value stays in `params`.

  This protocol does not provide storage, encoding, retries, recovery policy,
  effect delivery, effect deduplication, or exactly-once effects. Receipt
  payloads can contain terms such as exceptions, streams, PIDs, references,
  and functions. The host must encode and store the values that it accepts.
  See the execution guide for the uncertainty window and replay limits.
  """

  @typedoc "The stable role of one Action occurrence."
  @type role :: :root_action | :step | :choice | :map | :reduce | :iterate | :dispatch

  @typedoc """
  The selector for one Action occurrence.

  Choice uses an option name or fallback tag. Map, Reduce, and Iterate use a
  zero-based source or iteration index. Dispatch uses its decision or expander
  phase.
  """
  @type selector ::
          nil
          | %{required(:kind) => :option, required(:name) => String.t()}
          | %{required(:kind) => :fallback}
          | %{required(:index) => non_neg_integer()}
          | %{required(:phase) => :decision | :expander}

  @typedoc """
  The portable identity of one logical Action occurrence.

  `component_path` contains authored component names and all enclosing Subflow
  names. The initial root executable has chain index zero. Each accepted
  continuation increases the chain index.
  """
  @type occurrence_id :: %{
          required(:version) => 1,
          required(:run_key) => String.t(),
          required(:chain_index) => non_neg_integer(),
          required(:component_path) => [String.t()],
          required(:role) => role(),
          required(:selector) => selector()
        }

  @typedoc """
  Evidence for the current root or continuation executable segment.

  Digest values are evidence for a Flow definition. They do not identify all
  Action code or helper code.
  """
  @type executable_evidence :: %{
          required(:kind) => :action | :flow,
          required(:form) => :module | :value,
          required(:module) => module() | nil
        }

  @typedoc "Execution evidence that the host can use in its compatibility policy."
  @type evidence :: %{
          required(:executable) => executable_evidence(),
          required(:flow_semantic_digest) => binary() | nil,
          required(:compilation_digest) => binary() | nil
        }

  @typedoc """
  The immutable descriptor for the current Action invocation.

  `compatibility` is opaque host data. `params` contains resolved parameters
  before Action input validation. Raw execution context is not present.
  """
  @type invocation :: %{
          required(:version) => 1,
          required(:id) => occurrence_id(),
          required(:compatibility) => term(),
          required(:evidence) => evidence(),
          required(:action) => module(),
          required(:params) => term()
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

  @typedoc """
  A versioned receipt for one normalized Action outcome.

  The embedded descriptor is the historical descriptor from the attempt that
  made the receipt.
  """
  @type receipt :: %{
          required(:version) => 1,
          required(:invocation) => invocation(),
          required(:outcome) => outcome()
        }

  @typedoc """
  The optional Exec invocation configuration.

  `ref` and `compatibility` are opaque host terms. `run_key` must be a nonempty
  binary. One configuration applies to the complete continuation chain.
  """
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

  @doc """
  Chooses fresh execution, replay, or interruption before an Action invocation.

  Exec calls this function in the Action Task. A raised exception, throw,
  exit, or unsupported return interrupts the complete call.
  """
  @callback before_invoke(invocation(), ref :: term()) :: before_result()

  @doc """
  Accepts a fresh receipt or interrupts the complete call.

  Exec calls this function in the Action Task. Exec does not call it for a
  replayed receipt. A raised exception, throw, exit, or unsupported return
  interrupts the complete call.
  """
  @callback after_invoke(receipt(), ref :: term()) :: after_result()
end
