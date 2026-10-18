defmodule Jido.Exec.Handoff do
  @moduledoc """
  A validated request to finish a Turn and accept a successor in a fresh graph.

  Only a terminal Dispatch expander can return `{:handoff, params, target}`.
  The execution host must opt in with `host_capabilities: [:handoff]`.
  Exec returns `{:handoff, request, effects}` without running the successor.
  See [Dynamic Flows](dynamic-flows.md) for the host commit contract.
  """

  alias Jido.Exec.{Portable, Validation}
  alias Jido.Instruction

  @typedoc "Portable successor data. Chain and Turn IDs belong to the host."
  @type t :: %__MODULE__{target: module() | Jido.Flow.t(), kind: :action | :flow, params: map()}
  @enforce_keys [:target, :kind, :params]
  defstruct [:target, :kind, :params]

  @doc "Validates a successor target and its input without running Action work."
  @spec new(term(), term(), [atom()]) :: {:ok, t()} | {:error, Exception.t()}
  def new(target, params, capabilities \\ [:handoff]) do
    if is_list(capabilities) and not List.improper?(capabilities) and
         :handoff in capabilities and Enum.all?(capabilities, &(&1 == :handoff)) do
      with {:ok, instruction} <- Instruction.resolve(target, params),
           :ok <- Instruction.validate_resolved(instruction),
           {:ok, _workflow} <- Jido.Exec.compile(instruction),
           {:ok, params} <- Validation.input(instruction.target, instruction.params),
           :ok <- Portable.validate(params, :handoff_input) do
        {:ok, %__MODULE__{target: instruction.target, kind: instruction.kind, params: params}}
      end
    else
      {:error,
       Jido.Action.Error.config_error("execution host does not accept handoffs", %{
         reason: :unsupported_host,
         capability: :handoff
       })}
    end
  end
end

defimpl Runic.Identity.Projectable, for: Jido.Exec.Handoff do
  def identity_document(request) do
    %{
      kind: :jido_handoff,
      version: 1,
      target: request.target,
      target_kind: request.kind,
      params: request.params
    }
  end
end
