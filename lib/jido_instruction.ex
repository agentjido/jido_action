defmodule Jido.Instruction do
  @moduledoc """
  Defines the invocation value for one executable target.

  An Instruction contains a target, params, context, and metadata. The target
  follows the `Jido.Executable` contract. It can contain an Action module, a
  Flow module, or a runtime `Jido.Flow` value.

  The deprecated `:action` field and the typed `:flow` field are accepted as
  construction inputs. The module validates their executable kind and
  normalizes them to `:target`. A deprecated `:action` input emits a runtime
  warning. Canonical Instructions keep both target compatibility fields set to
  `nil`.

  The deprecated `:opts` field lets version 2 struct literals compile during
  migration. `Jido.Exec` consumes this field, emits a runtime warning, forwards
  supported options, and clears it before target execution. New code must pass
  execution options directly to `Jido.Exec.run/4`.

      %Jido.Instruction{
        target: MyApp.Actions.SendEmail,
        params: %{to: "user@example.com"},
        context: %{tenant_id: "tenant_123"},
        metadata: %{request_id: "req_123"}
      }

  The constructor resolves the target and validates the three invocation maps.
  It keeps the target value without conversion. Metadata has no execution
  meaning in this module.

  Constructor maps are not a stored or JSON representation. Executable module
  atoms and runtime Flow values do not have one general JSON form.
  """

  alias Jido.Action.Error
  alias Jido.Executable

  require Logger

  @target_fields [:target, :action, :flow]
  @removed_legacy_fields [:id]
  @forwarded_legacy_run_option_keys [:timeout, :task_supervisor]
  @forwarded_legacy_start_option_keys [:task_supervisor]
  @start_rejected_legacy_option_keys [:timeout]
  @removed_legacy_option_keys [
    :max_retries,
    :backoff,
    :log_level,
    :telemetry,
    :context_propagators,
    :context_propagator_failure_mode,
    :error_normalization
  ]
  @known_legacy_option_keys Enum.uniq(
                              @forwarded_legacy_run_option_keys ++
                                @removed_legacy_option_keys
                            )

  @schema Zoi.struct(
            __MODULE__,
            %{
              target: Zoi.any(description: "Executable target") |> Zoi.optional(),
              action: Zoi.any(description: "Deprecated Action target") |> Zoi.optional(),
              flow: Zoi.any(description: "Typed Flow target") |> Zoi.optional(),
              params: Zoi.map(description: "Executable parameters") |> Zoi.default(%{}),
              context: Zoi.map(description: "Execution context") |> Zoi.default(%{}),
              metadata: Zoi.map(description: "Invocation metadata") |> Zoi.default(%{}),
              opts:
                Zoi.list(Zoi.any(), description: "Deprecated version 2 execution options")
                |> Zoi.default([])
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))
  @type executable_target :: Executable.target()
  @type params :: map()
  @type context :: map()
  @type metadata :: map()

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc false
  @spec canonicalize(t()) ::
          {:ok, t(), Executable.t()} | {:error, Exception.t()}
  def canonicalize(%__MODULE__{} = instruction) do
    with {:ok, target, executable, source} <- resolve_instruction_target(instruction) do
      maybe_warn_deprecated_source(source, target)

      {:ok,
       %__MODULE__{
         instruction
         | target: target,
           action: nil,
           flow: nil
       }, executable}
    end
  end

  @doc false
  @spec prepare_execution(t(), term(), :run | :start) ::
          {:ok, t(), Executable.t(), term()} | {:error, Exception.t()}
  def prepare_execution(%__MODULE__{} = instruction, call_opts, mode)
      when mode in [:run, :start] do
    with {:ok, canonical, executable} <- canonicalize(instruction),
         {:ok, effective_opts} <-
           migrate_legacy_opts(instruction.opts, call_opts, canonical.target, mode) do
      {:ok, %{canonical | opts: []}, executable, effective_opts}
    end
  end

  @doc false
  @spec prepare_run_options(t(), term()) :: {:ok, term()} | {:error, Exception.t()}
  def prepare_run_options(%__MODULE__{} = instruction, call_opts) do
    migrate_legacy_opts(instruction.opts, call_opts, warning_target(instruction), :run)
  end

  @doc false
  @spec prepare_execution_target(t(), term()) ::
          {:ok, t(), Executable.t(), term()} | {:error, Exception.t()}
  def prepare_execution_target(%__MODULE__{} = instruction, effective_opts) do
    with {:ok, canonical, executable} <- canonicalize(instruction) do
      {:ok, %{canonical | opts: []}, executable, effective_opts}
    end
  end

  @doc false
  @spec normalize!(executable_target() | t(), map() | keyword(), map() | keyword()) :: t()
  def normalize!(target_or_instruction, params \\ %{}, context \\ %{}) do
    params = normalize_map!(params, :params)
    context = normalize_map!(context, :context)

    case target_or_instruction do
      %__MODULE__{} = instruction ->
        normalize_instruction!(instruction, params, context)

      target ->
        new!(%{target: target, params: params, context: context})
    end
  end

  defp normalize_instruction!(instruction, params, context) do
    normalized = merge_instruction!(instruction, params, context)

    case new(Map.from_struct(normalized)) do
      {:ok, normalized} ->
        normalized

      {:error, error} ->
        raise Error.validation_error("Invalid instruction configuration", %{reason: error})
    end
  end

  defp warning_target(%__MODULE__{target: target}) when not is_nil(target), do: target
  defp warning_target(%__MODULE__{action: action}) when not is_nil(action), do: action
  defp warning_target(%__MODULE__{flow: flow}) when not is_nil(flow), do: flow
  defp warning_target(_instruction), do: nil

  @doc false
  @spec normalize_resolved!(executable_target() | t(), map() | keyword(), map() | keyword()) ::
          t()
  def normalize_resolved!(target_or_instruction, params, context) do
    params = normalize_map!(params, :params)
    context = normalize_map!(context, :context)

    case target_or_instruction do
      %__MODULE__{} = instruction ->
        instruction
        |> canonicalize_resolved_instruction!()
        |> merge_instruction!(params, context)

      target ->
        %__MODULE__{target: target, params: params, context: context, metadata: %{}}
    end
  end

  defp canonicalize_resolved_instruction!(%__MODULE__{action: nil, flow: nil} = instruction),
    do: instruction

  defp canonicalize_resolved_instruction!(%__MODULE__{} = instruction) do
    case canonicalize(instruction) do
      {:ok, canonical, _executable} -> canonical
      {:error, error} -> raise error
    end
  end

  defp merge_instruction!(instruction, params, context) do
    %__MODULE__{
      target: instruction.target,
      action: instruction.action,
      flow: instruction.flow,
      params: Map.merge(normalize_map!(instruction.params || %{}, :params), params),
      context: Map.merge(normalize_map!(instruction.context || %{}, :context), context),
      metadata: normalize_map!(instruction.metadata || %{}, :metadata),
      opts: normalize_legacy_opts!(instruction.opts)
    }
  end

  @spec normalize_map!(term(), atom()) :: map()
  defp normalize_map!(value, field) do
    case normalize_map_field(value, field) do
      {:ok, map} ->
        map

      {:error, _error} ->
        raise ArgumentError, normalize_map_message(value, field)
    end
  end

  @doc """
  Creates an instruction from a map or keyword list.

  Exactly one of `:target`, `:action`, or `:flow` must identify the executable.
  `:target` accepts either executable kind. `:action` accepts only an Action
  and emits a migration warning. `:flow` accepts only a Flow. The constructor
  normalizes either typed field to `:target`.

  `:params`, `:context`, and `:metadata` are optional. The three invocation
  fields can be maps or keyword lists. The deprecated `:opts` field accepts a
  keyword list for version 2 migration. `Jido.Exec` warns when it consumes a
  non-empty value.
  """
  @spec new(map() | keyword()) :: {:ok, t()} | {:error, Exception.t()}
  def new(attrs) when is_list(attrs) do
    if Keyword.keyword?(attrs) do
      attrs |> Map.new() |> new()
    else
      {:error,
       Error.validation_error("Invalid instruction configuration", %{
         reason: :invalid_attributes
       })}
    end
  end

  def new(%{} = attrs) do
    with :ok <- reject_removed_legacy_fields(attrs),
         {:ok, target, _executable, source} <- resolve_instruction_target(attrs),
         {:ok, params} <- normalize_map_field(Map.get(attrs, :params, %{}), :params),
         {:ok, context} <- normalize_map_field(Map.get(attrs, :context, %{}), :context),
         {:ok, metadata} <- normalize_map_field(Map.get(attrs, :metadata, %{}), :metadata),
         {:ok, opts} <- normalize_legacy_opts(Map.get(attrs, :opts, [])) do
      maybe_warn_deprecated_source(source, target)

      {:ok,
       %__MODULE__{
         target: target,
         action: nil,
         flow: nil,
         params: params,
         context: context,
         metadata: metadata,
         opts: opts
       }}
    end
  end

  def new(_attrs) do
    {:error,
     Error.validation_error("Invalid instruction configuration", %{
       reason: :invalid_attributes
     })}
  end

  @doc """
  Creates an instruction or raises on failure.
  """
  @spec new!(map() | keyword()) :: t() | no_return()
  def new!(attrs) do
    case new(attrs) do
      {:ok, instruction} ->
        instruction

      {:error, error} when is_exception(error) ->
        raise error

      {:error, error} ->
        raise Error.validation_error("Invalid instruction configuration", %{reason: error})
    end
  end

  defp resolve_instruction_target(%__MODULE__{} = instruction) do
    if is_nil(instruction.target) and is_nil(instruction.action) and is_nil(instruction.flow) do
      resolve_selected_target(:target, nil)
    else
      instruction
      |> Map.from_struct()
      |> resolve_instruction_target()
    end
  end

  defp resolve_instruction_target(attrs) do
    case populated_target_fields(attrs) do
      [] ->
        case present_target_fields(attrs) do
          [source] -> resolve_selected_target(source, Map.fetch!(attrs, source))
          _fields -> missing_target_error()
        end

      [source] ->
        resolve_selected_target(source, Map.fetch!(attrs, source))

      fields ->
        {:error,
         Error.validation_error("Instruction target fields conflict", %{
           fields: fields,
           reason: :conflicting_target_fields
         })}
    end
  end

  defp resolve_selected_target(source, target) do
    with {:ok, %Executable{} = executable} <- Executable.resolve(target),
         :ok <- validate_source_kind(source, target, executable) do
      {:ok, target, executable, source}
    end
  end

  defp missing_target_error do
    {:error,
     Error.validation_error("Invalid instruction configuration", %{
       field: :target,
       reason: :missing
     })}
  end

  defp populated_target_fields(attrs) do
    Enum.filter(@target_fields, fn field ->
      Map.has_key?(attrs, field) and not is_nil(Map.get(attrs, field))
    end)
  end

  defp present_target_fields(attrs) do
    Enum.filter(@target_fields, &Map.has_key?(attrs, &1))
  end

  defp validate_source_kind(:target, _target, %Executable{}), do: :ok
  defp validate_source_kind(:action, _target, %Executable{kind: :action}), do: :ok
  defp validate_source_kind(:flow, _target, %Executable{kind: :flow}), do: :ok

  defp validate_source_kind(source, target, %Executable{kind: actual_kind}) do
    expected_kind = source

    {:error,
     Error.validation_error("Instruction #{inspect(source)} field has the wrong target kind", %{
       actual_kind: actual_kind,
       expected_kind: expected_kind,
       field: source,
       target: target
     })}
  end

  defp reject_removed_legacy_fields(attrs) do
    fields = Enum.filter(@removed_legacy_fields, &Map.has_key?(attrs, &1))

    case fields do
      [] ->
        :ok

      fields ->
        {:error,
         Error.validation_error("Removed Instruction fields are not supported", %{
           fields: fields,
           reason: :removed_instruction_fields
         })}
    end
  end

  defp maybe_warn_deprecated_source(:action, target) do
    Logger.warning(
      "Jido.Instruction received the deprecated :action field for #{inspect(target)}. " <>
        "Use :target instead. Jido normalized the Instruction and continued."
    )
  end

  defp maybe_warn_deprecated_source(_source, _target), do: :ok

  defp migrate_legacy_opts(opts, call_opts, target, mode) do
    case normalize_legacy_opts(opts) do
      {:ok, []} ->
        {:ok, call_opts}

      {:ok, legacy_opts} ->
        with :ok <- Jido.Exec.Runtime.reject_jido(legacy_opts) do
          migrate_normalized_legacy_opts(legacy_opts, call_opts, target, mode)
        end

      {:error, error} ->
        warn_invalid_legacy_opts(target, mode)
        {:error, error}
    end
  end

  defp migrate_normalized_legacy_opts(legacy_opts, call_opts, target, mode) do
    keys = legacy_opts |> Keyword.keys() |> Enum.uniq()
    forwarded_keys = Enum.filter(keys, &(&1 in forwarded_legacy_option_keys(mode)))
    rejected_keys = Enum.filter(keys, &start_rejected_option?(mode, &1))
    removed_keys = Enum.filter(keys, &(&1 in @removed_legacy_option_keys))
    unknown_keys = Enum.reject(keys, &(&1 in @known_legacy_option_keys))

    warn_legacy_opts(target, mode, forwarded_keys, rejected_keys, removed_keys, unknown_keys)

    case unknown_keys do
      [] ->
        legacy_opts
        |> Keyword.take(forwarded_keys ++ rejected_keys)
        |> merge_call_opts(call_opts)

      _unknown_keys ->
        {:error,
         Error.validation_error("Unknown deprecated Instruction options", %{
           options: unknown_keys,
           reason: :unknown_instruction_options
         })}
    end
  end

  defp forwarded_legacy_option_keys(:run), do: @forwarded_legacy_run_option_keys
  defp forwarded_legacy_option_keys(:start), do: @forwarded_legacy_start_option_keys

  defp start_rejected_option?(:start, key), do: key in @start_rejected_legacy_option_keys
  defp start_rejected_option?(_mode, _key), do: false

  defp merge_call_opts([], call_opts), do: {:ok, call_opts}

  defp merge_call_opts(legacy_opts, call_opts) when is_list(call_opts) do
    if Keyword.keyword?(call_opts) do
      {:ok, Keyword.merge(legacy_opts, call_opts)}
    else
      invalid_call_opts()
    end
  end

  defp merge_call_opts(_legacy_opts, _call_opts), do: invalid_call_opts()

  defp invalid_call_opts do
    {:error,
     Error.validation_error("run options must be a keyword list", %{
       reason: :invalid_execution_options
     })}
  end

  defp warn_legacy_opts(target, mode, forwarded, rejected, removed, unknown) do
    parts = [
      "Jido.Instruction received the deprecated :opts field for #{inspect(target)}.",
      forwarded_options_warning(mode, forwarded),
      rejected_options_warning(mode, rejected),
      removed_options_warning(removed),
      unknown_options_warning(unknown),
      "Move execution options to Jido.Exec.#{mode}/4. " <>
        "New code must not store execution policy in Jido.Instruction."
    ]

    parts
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
    |> Logger.warning()
  end

  defp forwarded_options_warning(_mode, []), do: nil

  defp forwarded_options_warning(mode, keys),
    do: "Forwarded to Jido.Exec.#{mode}/4: #{inspect(keys)}."

  defp rejected_options_warning(_mode, []), do: nil

  defp rejected_options_warning(:start, keys) do
    "Not applied by Jido.Exec.start/4: #{inspect(keys)}. " <>
      "A paused Flow does not have a whole-call timeout."
  end

  defp removed_options_warning([]), do: nil

  defp removed_options_warning(keys) do
    retry_note =
      if :max_retries in keys or :backoff in keys,
        do: " This call runs once; move retry policy to the caller or Jido runtime.",
        else: ""

    "Not applied because Jido Action 3 removed them: #{inspect(keys)}." <> retry_note
  end

  defp unknown_options_warning([]), do: nil

  defp unknown_options_warning(keys),
    do: "Unknown options cannot be migrated: #{inspect(keys)}. Jido cannot continue."

  defp warn_invalid_legacy_opts(target, mode) do
    Logger.warning(
      "Jido.Instruction received an invalid deprecated :opts field for #{inspect(target)}. " <>
        "Move execution options to Jido.Exec.#{mode}/4. " <>
        "The value must be a keyword list."
    )
  end

  defp normalize_legacy_opts(nil), do: {:ok, []}

  defp normalize_legacy_opts(value) when is_list(value) do
    if Keyword.keyword?(value) do
      {:ok, value}
    else
      invalid_legacy_opts()
    end
  end

  defp normalize_legacy_opts(_value), do: invalid_legacy_opts()

  defp normalize_legacy_opts!(value) do
    case normalize_legacy_opts(value) do
      {:ok, opts} -> opts
      {:error, _error} -> raise ArgumentError, "expected opts to be a keyword list"
    end
  end

  defp invalid_legacy_opts do
    {:error,
     Error.validation_error("Invalid deprecated Instruction opts", %{
       field: :opts,
       reason: :not_keyword_list
     })}
  end

  defp normalize_map_field(nil, _field), do: {:ok, %{}}
  defp normalize_map_field(value, _field) when is_map(value), do: {:ok, value}

  defp normalize_map_field(value, field) when is_list(value) do
    if Keyword.keyword?(value) do
      {:ok, Map.new(value)}
    else
      invalid_map_field(field, value)
    end
  end

  defp normalize_map_field(value, field), do: invalid_map_field(field, value)

  defp invalid_map_field(field, value) do
    label = Atom.to_string(field)

    {:error,
     Error.validation_error(
       "Invalid #{label} format. #{String.capitalize(label)} must be a map or keyword list.",
       %{
         field => value,
         expected_format: "%{key: value} or [key: value]"
       }
     )}
  end

  defp normalize_map_message(value, _field) when is_list(value),
    do: "expected a map or keyword list, got: #{inspect(value)}"

  defp normalize_map_message(value, field),
    do: "expected #{field} to be a map or keyword list, got: #{inspect(value)}"
end
