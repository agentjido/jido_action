defmodule Jido.Exec.ContextPropagator do
  @moduledoc """
  Behaviour for propagating process-local runtime context across supervised work.

  Implementations can capture ambient caller state in `capture/0`, attach it in a
  child process with `attach/1`, and clean up in `detach/1`.

  This is intentionally backend-agnostic so packages such as `jido_otel` can
  bridge tracing context without `jido_action` depending on a specific
  observability library.
  """

  @typedoc """
  Opaque context captured in the parent process.
  """
  @type captured_ctx :: term()

  @typedoc """
  Opaque token returned by `attach/1` and passed to `detach/1`.
  """
  @type attached_ctx :: term()

  @doc """
  Captures process-local runtime context in the caller process.
  """
  @callback capture() :: captured_ctx()

  @doc """
  Attaches previously captured context in the child process.
  """
  @callback attach(captured_ctx()) :: attached_ctx()

  @doc """
  Cleans up any state created by `attach/1`.
  """
  @callback detach(attached_ctx()) :: :ok
end
