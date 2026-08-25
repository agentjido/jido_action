defmodule Jido.Executable do
  @moduledoc """
  Defines the common executable contract for Jido Actions and Jido Flows.

  An executable target is one of these values:

  * an Action module with `__jido_executable__/0`;
  * a Flow module with `__jido_executable__/0`; or
  * a `Jido.Flow` value.

  Resolution returns the target kind and the exact target:

      {:ok, %Jido.Executable{kind: :action, target: MyApp.SendEmail}} =
        Jido.Executable.resolve(MyApp.SendEmail)

  `resolve/1` keeps the exact target and returns one small descriptor.
  A module callback must identify the module that owns the callback.

  A Flow module must return one stable `%Jido.Flow{}` from `flow/0` for the life
  of the loaded module version. Each validation or execution operation
  materializes the value once.

  `Jido.Instruction` stores one of these target values and resolves it through
  this module. The target kind selects the Action or Flow execution semantics.

  Resolution failures use `Jido.Action.Error.ConfigurationError` because the
  resolver does not yet know the target kind. Action or Flow execution owns
  errors after resolution. This keeps one resolver and avoids a separate
  executable error model.

  This module does not define a map or JSON format for executable targets.
  """

  alias Jido.Action.Error
  alias Jido.Flow

  @typedoc "The executable kind."
  @type kind :: :action | :flow

  @typedoc "An Action module, a Flow module, or a runtime Flow value."
  @type target :: module() | Flow.t()

  @schema Zoi.struct(
            __MODULE__,
            %{
              kind: Zoi.enum([:action, :flow], description: "Executable kind"),
              target: Zoi.any(description: "Resolved executable target")
            },
            coerce: true
          )

  @typedoc "The resolved executable descriptor."
  @type t :: unquote(Zoi.type_spec(@schema))

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc false
  @callback __jido_executable__() :: t()

  @doc false
  @spec action(module()) :: t()
  def action(module) when is_atom(module) and not is_nil(module) do
    %__MODULE__{kind: :action, target: module}
  end

  @doc false
  @spec flow(module() | Flow.t()) :: t()
  def flow(%Flow{} = target) do
    %__MODULE__{kind: :flow, target: target}
  end

  def flow(target) when is_atom(target) and not is_nil(target) do
    %__MODULE__{kind: :flow, target: target}
  end

  @doc """
  Resolves an executable target.

  Action and Flow modules must return a valid descriptor from
  `__jido_executable__/0`. A loaded module without this callback is not an
  executable target.
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

  @doc "Validates an executable descriptor or target."
  @spec validate(t() | target() | term()) :: :ok | {:error, Exception.t()}
  def validate(%__MODULE__{kind: :action, target: target})
      when is_atom(target) and not is_nil(target) do
    validate_action_compatible_callbacks(target)
  end

  def validate(%__MODULE__{kind: :flow, target: %Flow{}}), do: :ok

  def validate(%__MODULE__{kind: :flow, target: target})
      when is_atom(target) and not is_nil(target) do
    with :ok <- validate_action_compatible_callbacks(target) do
      if function_exported?(target, :flow, 0) do
        :ok
      else
        invalid_executable_contract(target, "missing flow/0")
      end
    end
  end

  def validate(%__MODULE__{} = executable) do
    {:error,
     Error.config_error("invalid executable descriptor", %{
       executable: executable,
       reason: :invalid_descriptor
     })}
  end

  def validate(target) do
    with {:ok, executable} <- resolve(target) do
      validate(executable)
    end
  end

  defp validate_action_compatible_callbacks(module) do
    cond do
      not function_exported?(module, :run, 2) ->
        invalid_executable_contract(module, "missing run/2")

      not function_exported?(module, :validate_params, 1) ->
        invalid_executable_contract(module, "missing validate_params/1")

      not function_exported?(module, :validate_output, 1) ->
        invalid_executable_contract(module, "missing validate_output/1")

      true ->
        :ok
    end
  end

  defp resolve_loaded_module(module) do
    if function_exported?(module, :__jido_executable__, 0) do
      resolve_module_descriptor(module)
    else
      unknown_executable(module, :missing_descriptor)
    end
  end

  defp resolve_module_descriptor(module) do
    module
    |> invoke_descriptor()
    |> validate_descriptor(module)
  rescue
    error -> descriptor_callback_error(module, error)
  catch
    kind, reason -> descriptor_callback_error(module, {kind, reason})
  end

  defp invoke_descriptor(module), do: module.__jido_executable__()

  defp validate_descriptor(%__MODULE__{kind: kind, target: module} = executable, module)
       when kind in [:action, :flow] do
    {:ok, executable}
  end

  defp validate_descriptor(descriptor, module) do
    {:error,
     Error.config_error("invalid executable descriptor", %{
       executable: module,
       descriptor: descriptor,
       reason: :invalid_descriptor
     })}
  end

  defp descriptor_callback_error(module, error) do
    {:error,
     Error.config_error("invalid executable descriptor", %{
       executable: module,
       error: error,
       reason: :descriptor_callback_failed
     })}
  end

  defp invalid_executable_contract(executable, reason) do
    {:error,
     Error.validation_error("module is not a valid Jido executable", %{
       executable: executable,
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
