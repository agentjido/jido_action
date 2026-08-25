defmodule Jido.Executable do
  @moduledoc """
  Defines the common executable contract for Jido Actions and Jido Flows.

  Modules that use `Jido.Action` or `Jido.Flow` expose one generated
  `__jido_executable__/0` descriptor. `resolve/1` converts Action modules,
  Flow modules, and `Jido.Flow` artifacts to the same internal descriptor.

  The adapter field is an internal execution detail. It keeps Action and Flow
  execution semantics separate. It is not a general plugin interface.
  """

  alias Jido.Action.Error
  alias Jido.Flow

  @action_adapter Jido.Exec.ActionAdapter
  @flow_adapter Jido.Exec.FlowAdapter

  @typedoc "The executable kind."
  @type kind :: :action | :flow

  @schema Zoi.struct(
            __MODULE__,
            %{
              kind: Zoi.enum([:action, :flow], description: "Executable kind"),
              target: Zoi.any(description: "Resolved executable target"),
              adapter: Zoi.atom(description: "Internal execution adapter")
            },
            coerce: true
          )

  @typedoc "The internal resolved executable descriptor."
  @type t :: unquote(Zoi.type_spec(@schema))

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc false
  @callback __jido_executable__() :: t()

  @doc false
  @spec action(module()) :: t()
  def action(module) when is_atom(module) and not is_nil(module) do
    %__MODULE__{kind: :action, target: module, adapter: @action_adapter}
  end

  @doc false
  @spec flow(module() | Flow.t()) :: t()
  def flow(target) do
    %__MODULE__{kind: :flow, target: target, adapter: @flow_adapter}
  end

  @doc """
  Resolves an Action module, Flow module, or Flow artifact.

  The result is one internal executable descriptor. Modules that use the
  current Jido macros provide this descriptor directly. Callback-only Action
  modules continue to resolve as Actions and use the same callback validation
  rules as before.
  """
  @spec resolve(term()) :: {:ok, t()} | {:error, Error.ConfigurationError.t()}
  def resolve(%Flow{} = flow), do: {:ok, flow(flow)}

  def resolve(module) when is_atom(module) and not is_nil(module) do
    case Code.ensure_loaded(module) do
      {:module, _module} -> resolve_loaded_module(module)
      {:error, reason} -> unknown_executable(module, reason)
    end
  end

  def resolve(executable), do: unknown_executable(executable, nil)

  @doc false
  @spec validate(t()) :: :ok | {:error, Exception.t()}
  def validate(%__MODULE__{adapter: adapter} = executable) do
    adapter.validate(executable)
  end

  @doc false
  @spec validate_module_callbacks(module()) :: :ok | {:error, Exception.t()}
  def validate_module_callbacks(module) do
    cond do
      not function_exported?(module, :run, 2) ->
        invalid_action_contract(module, "missing run/2")

      not function_exported?(module, :validate_params, 1) ->
        invalid_action_contract(module, "missing validate_params/1")

      not function_exported?(module, :validate_output, 1) ->
        invalid_action_contract(module, "missing validate_output/1")

      true ->
        :ok
    end
  end

  defp resolve_loaded_module(module) do
    if function_exported?(module, :__jido_executable__, 0) do
      module
      |> invoke_descriptor()
      |> validate_descriptor(module)
    else
      {:ok, action(module)}
    end
  end

  defp invoke_descriptor(module), do: module.__jido_executable__()

  defp validate_descriptor(
         %__MODULE__{kind: kind, target: module, adapter: adapter} = executable,
         module
       )
       when (kind == :action and adapter == @action_adapter) or
              (kind == :flow and adapter == @flow_adapter) do
    {:ok, executable}
  end

  defp validate_descriptor(descriptor, module) do
    {:error,
     Error.config_error("invalid executable descriptor", %{
       executable: module,
       descriptor: descriptor
     })}
  end

  defp invalid_action_contract(action, reason) do
    {:error,
     Error.validation_error("module is not a valid Jido action", %{
       action: action,
       reason: reason
     })}
  end

  defp unknown_executable(executable, nil) do
    {:error,
     Error.config_error("unknown executable: #{inspect(executable)}", %{executable: executable})}
  end

  defp unknown_executable(executable, reason) do
    {:error,
     Error.config_error("unknown executable: #{inspect(executable)}", %{
       executable: executable,
       reason: reason
     })}
  end
end
