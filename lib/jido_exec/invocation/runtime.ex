defmodule Jido.Exec.Invocation.Runtime do
  @moduledoc false

  alias Jido.Action.Output
  alias Jido.Exec.Error
  alias Jido.Exec.Invocation
  alias Jido.Exec.Controller
  alias Jido.Exec.Transition
  alias Jido.Exec.Flow.Compiled
  alias Jido.Exec.Flow.Target

  @config_keys [:host, :ref, :run_key, :compatibility]
  @invocation_keys [:version, :id, :compatibility, :evidence, :action, :params]
  @id_keys [:version, :run_key, :chain_index, :component_path, :role, :selector]
  @evidence_keys [:executable, :flow_semantic_digest, :compilation_digest]
  @executable_keys [:kind, :form, :module]
  @receipt_keys [:version, :invocation, :outcome]

  @type config_error :: %{
          required(:reason) => :missing | :invalid | :invalid_configuration,
          optional(:field) => atom(),
          optional(:fields) => [term()]
        }

  @doc false
  @spec validate_config(term()) :: {:ok, Invocation.config()} | {:error, config_error()}
  def validate_config(config) when is_map(config) and not is_struct(config) do
    with :ok <- validate_required_config_fields(config),
         :ok <- validate_config_keys(config),
         :ok <- validate_host(config.host),
         :ok <- validate_run_key(config.run_key) do
      {:ok, config}
    end
  end

  def validate_config(_config), do: {:error, %{reason: :invalid_configuration}}

  @doc false
  @spec descriptor(
          Invocation.config(),
          Invocation.occurrence_id(),
          Invocation.evidence(),
          module(),
          term()
        ) ::
          Invocation.invocation()
  def descriptor(config, id, evidence, action, params) do
    %{
      version: 1,
      id: id,
      compatibility: config.compatibility,
      evidence: evidence,
      action: action,
      params: params
    }
  end

  @doc false
  @spec receipt(Invocation.invocation(), Invocation.outcome()) :: Invocation.receipt()
  def receipt(invocation, outcome), do: %{version: 1, invocation: invocation, outcome: outcome}

  @doc false
  @spec action_evidence(module()) :: Invocation.evidence()
  def action_evidence(action) do
    %{
      executable: %{kind: :action, form: :module, module: action},
      flow_semantic_digest: nil,
      compilation_digest: nil
    }
  end

  @doc false
  @spec flow_evidence(module() | Jido.Flow.t(), Compiled.t()) :: Invocation.evidence()
  def flow_evidence(target, %Compiled{} = compiled) do
    executable =
      case target do
        module when is_atom(module) -> %{kind: :flow, form: :module, module: module}
        %Jido.Flow{} -> %{kind: :flow, form: :value, module: nil}
      end

    %{
      executable: executable,
      flow_semantic_digest: compiled.semantic_digest,
      compilation_digest: compiled.compilation_digest
    }
  end

  @doc false
  @spec root_id(Invocation.config(), non_neg_integer()) :: Invocation.occurrence_id()
  def root_id(config, chain_index) do
    occurrence_id(config, chain_index, [], :root_action, nil)
  end

  @doc false
  @spec target_id(Invocation.config(), non_neg_integer(), Target.t()) ::
          Invocation.occurrence_id()
  def target_id(config, chain_index, instruction) do
    kind = Target.kind(instruction)
    details = Target.details(instruction)
    path = Map.get(details, :node_path, [details.node])

    {role, selector} =
      case kind do
        :step -> {:step, nil}
        :choice -> {:choice, choice_selector(Map.fetch!(details, :option))}
        :map -> {:map, %{index: Map.fetch!(details, :item_index)}}
        :reduce -> {:reduce, %{index: Map.fetch!(details, :item_index)}}
        :iterate -> {:iterate, %{index: Map.fetch!(details, :iteration_index)}}
        :dispatch -> {:dispatch, %{phase: Map.fetch!(details, :dispatch_phase)}}
      end

    occurrence_id(config, chain_index, path, role, selector)
  end

  @doc false
  @spec invoke(
          Invocation.config(),
          Invocation.invocation(),
          module(),
          map(),
          Controller.call(),
          (-> term())
        ) :: term()
  def invoke(config, invocation, action, context, control, work) when is_function(work, 0) do
    Controller.halt_if_interrupted(control)

    case before(config, invocation) do
      {:ok, :execute} ->
        Controller.begin_fresh_work(control)
        result = work.()
        receipt = receipt(invocation, result_to_outcome(result))

        case after_invoke(config, receipt) do
          :ok ->
            Controller.accept_fresh_work(control)
            result

          {:error, error} ->
            Controller.interrupt_invocation(control, error)
        end

      {:ok, {:replay, receipt}} ->
        outcome_to_result(receipt.outcome, action, context)

      {:error, error} ->
        Controller.interrupt_invocation(control, error)
    end
  end

  @doc false
  @spec before(Invocation.config(), Invocation.invocation()) ::
          {:ok, :execute | {:replay, Invocation.receipt()}} | {:error, Error.InterruptedError.t()}
  def before(config, invocation) do
    stage = :before_invoke
    invocation_id = invocation_id(invocation)

    case call(config.host, :before_invoke, [invocation, config.ref]) do
      {:ok, :execute} ->
        {:ok, :execute}

      {:ok, {:replay, receipt}} ->
        case validate_receipt(receipt, invocation) do
          {:ok, receipt} -> {:ok, {:replay, receipt}}
          {:error, _error} = error -> error
        end

      {:ok, {:interrupt, reason}} ->
        {:error, Error.interrupted_error(stage, reason, invocation_id)}

      {:ok, {:error, reason}} ->
        {:error, Error.interrupted_error(stage, reason, invocation_id)}

      {:ok, other} ->
        {:error, Error.interrupted_error(stage, {:invalid_callback_return, other}, invocation_id)}

      {:error, reason, stacktrace} ->
        {:error, callback_failure(stage, reason, invocation_id, stacktrace)}
    end
  end

  @doc false
  @spec after_invoke(Invocation.config(), Invocation.receipt()) ::
          :ok | {:error, Error.InterruptedError.t()}
  def after_invoke(config, receipt) do
    stage = :after_invoke
    invocation_id = receipt_invocation_id(receipt)

    case call(config.host, :after_invoke, [receipt, config.ref]) do
      {:ok, :ok} ->
        :ok

      {:ok, {:interrupt, reason}} ->
        {:error, Error.interrupted_error(stage, reason, invocation_id)}

      {:ok, {:error, reason}} ->
        {:error, Error.interrupted_error(stage, reason, invocation_id)}

      {:ok, other} ->
        {:error, Error.interrupted_error(stage, {:invalid_callback_return, other}, invocation_id)}

      {:error, reason, stacktrace} ->
        {:error, callback_failure(stage, reason, invocation_id, stacktrace)}
    end
  end

  @doc false
  @spec validate_receipt(term(), Invocation.invocation()) ::
          {:ok, Invocation.receipt()} | {:error, Error.InterruptedError.t()}
  def validate_receipt(receipt, current_invocation) do
    invocation_id = invocation_id(current_invocation)

    case do_validate_receipt(receipt, current_invocation) do
      :ok -> {:ok, receipt}
      {:error, reason} -> {:error, Error.interrupted_error(:replay, reason, invocation_id)}
    end
  end

  defp do_validate_receipt(receipt, current_invocation) do
    with :ok <- validate_exact_map(receipt, @receipt_keys, :invalid_receipt),
         :ok <- validate_version(receipt.version, :unsupported_receipt_version),
         :ok <- validate_invocation(receipt.invocation),
         :ok <- validate_current_invocation(current_invocation),
         :ok <- validate_occurrence(receipt.invocation.id, current_invocation.id) do
      validate_outcome(receipt.outcome)
    end
  end

  defp occurrence_id(config, chain_index, component_path, role, selector) do
    %{
      version: 1,
      run_key: config.run_key,
      chain_index: chain_index,
      component_path: component_path,
      role: role,
      selector: selector
    }
  end

  defp choice_selector(:fallback), do: %{kind: :fallback}
  defp choice_selector(name), do: %{kind: :option, name: name}

  defp result_to_outcome({:ok, output}),
    do: %{kind: :ok, output: output, effects: []}

  defp result_to_outcome({:ok, output, effects}),
    do: %{kind: :ok, output: output, effects: effects}

  defp result_to_outcome({:error, phase, error}),
    do: %{kind: :error, phase: phase, error: error}

  defp result_to_outcome({:continue, %Transition{} = transition}),
    do: %{kind: :continue, input: transition.input, target: transition.target}

  defp outcome_to_result(%{kind: :ok, output: output, effects: effects}, _action, _context),
    do: {:ok, output, effects}

  defp outcome_to_result(%{kind: :error, phase: phase, error: error}, _action, _context),
    do: {:error, phase, error}

  defp outcome_to_result(%{kind: :continue, input: input, target: target}, action, context),
    do: {:continue, Transition.new(input, target, action, context)}

  defp validate_invocation(invocation) do
    with :ok <- validate_exact_map(invocation, @invocation_keys, :invalid_invocation),
         :ok <- validate_version(invocation.version, :unsupported_invocation_version),
         :ok <- validate_id(invocation.id),
         :ok <- validate_evidence(invocation.evidence),
         true <- is_atom(invocation.action) and not is_nil(invocation.action) do
      :ok
    else
      {:error, _reason} = error -> error
      false -> invalid(:invalid_invocation)
    end
  end

  defp validate_current_invocation(invocation) do
    case validate_invocation(invocation) do
      :ok -> :ok
      {:error, reason} -> {:error, {:invalid_current_invocation, reason}}
    end
  end

  defp validate_id(id) do
    with :ok <- validate_exact_map(id, @id_keys, :invalid_invocation),
         :ok <- validate_version(id.version, :unsupported_identity_version),
         true <- is_binary(id.run_key) and byte_size(id.run_key) > 0,
         true <- is_integer(id.chain_index) and id.chain_index >= 0,
         true <- valid_component_path?(id.component_path),
         true <- valid_role_selector?(id.role, id.selector, id.component_path) do
      :ok
    else
      {:error, _reason} = error -> error
      false -> invalid(:invalid_invocation)
    end
  end

  defp validate_evidence(evidence) do
    with :ok <- validate_exact_map(evidence, @evidence_keys, :invalid_invocation),
         :ok <- validate_executable_evidence(evidence.executable),
         true <- binary_or_nil?(evidence.flow_semantic_digest),
         true <- binary_or_nil?(evidence.compilation_digest) do
      :ok
    else
      {:error, _reason} = error -> error
      false -> invalid(:invalid_invocation)
    end
  end

  defp validate_executable_evidence(executable) do
    with :ok <- validate_exact_map(executable, @executable_keys, :invalid_invocation),
         true <- valid_executable_evidence?(executable) do
      :ok
    else
      {:error, _reason} = error -> error
      false -> invalid(:invalid_invocation)
    end
  end

  defp validate_occurrence(id, id), do: :ok
  defp validate_occurrence(_historical, _current), do: invalid(:wrong_occurrence_key)

  defp validate_outcome(%{kind: :ok} = outcome) do
    with :ok <- validate_exact_keys(outcome, [:kind, :output, :effects], :invalid_outcome),
         true <- valid_output?(outcome.output),
         true <- proper_list?(outcome.effects) do
      :ok
    else
      {:error, _reason} = error -> error
      false -> invalid(:invalid_outcome)
    end
  end

  defp validate_outcome(%{kind: :error} = outcome) do
    with :ok <- validate_exact_keys(outcome, [:kind, :phase, :error], :invalid_outcome),
         true <- outcome.phase in [:input, :execution, :output],
         true <- is_exception(outcome.error) do
      :ok
    else
      {:error, _reason} = error -> error
      false -> invalid(:invalid_outcome)
    end
  end

  defp validate_outcome(%{kind: :continue} = outcome) do
    with :ok <- validate_exact_keys(outcome, [:kind, :input, :target], :invalid_outcome),
         true <- is_map(outcome.input) and not match?(%Output{}, outcome.input) do
      :ok
    else
      {:error, _reason} = error -> error
      false -> invalid(:invalid_outcome)
    end
  end

  defp validate_outcome(_outcome), do: invalid(:invalid_outcome)

  defp validate_required_config_fields(config) do
    case Enum.find(@config_keys, &(not Map.has_key?(config, &1))) do
      nil -> :ok
      field -> {:error, %{reason: :missing, field: field}}
    end
  end

  defp validate_config_keys(config) do
    if map_size(config) == length(@config_keys) do
      :ok
    else
      {:error, %{reason: :invalid_configuration, fields: Map.keys(config)}}
    end
  end

  defp validate_host(host) when is_atom(host) and not is_nil(host) do
    if Code.ensure_loaded?(host) and function_exported?(host, :before_invoke, 2) and
         function_exported?(host, :after_invoke, 2) do
      :ok
    else
      {:error, %{reason: :invalid, field: :host}}
    end
  end

  defp validate_host(_host), do: {:error, %{reason: :invalid, field: :host}}

  defp validate_run_key(run_key) when is_binary(run_key) and byte_size(run_key) > 0, do: :ok
  defp validate_run_key(_run_key), do: {:error, %{reason: :invalid, field: :run_key}}

  defp validate_exact_map(value, keys, reason)
       when is_map(value) and not is_struct(value),
       do: validate_exact_keys(value, keys, reason)

  defp validate_exact_map(_value, _keys, reason), do: invalid(reason)

  defp validate_exact_keys(map, keys, reason) do
    if map_size(map) == length(keys) and Enum.all?(keys, &Map.has_key?(map, &1)) do
      :ok
    else
      invalid(reason)
    end
  end

  defp validate_version(1, _reason), do: :ok
  defp validate_version(version, reason), do: {:error, {reason, %{version: version}}}

  defp valid_component_path?(path) do
    is_list(path) and not List.improper?(path) and Enum.all?(path, &is_binary/1)
  end

  defp valid_role_selector?(:root_action, nil, []), do: true
  defp valid_role_selector?(:step, nil, _path), do: true

  defp valid_role_selector?(:choice, %{kind: :fallback} = selector, _path),
    do: exact_shape?(selector, [:kind])

  defp valid_role_selector?(:choice, %{kind: :option, name: name} = selector, _path),
    do: exact_shape?(selector, [:kind, :name]) and is_binary(name)

  defp valid_role_selector?(role, %{index: index} = selector, _path)
       when role in [:map, :reduce, :iterate],
       do: exact_shape?(selector, [:index]) and is_integer(index) and index >= 0

  defp valid_role_selector?(:dispatch, %{phase: phase} = selector, _path),
    do: exact_shape?(selector, [:phase]) and phase in [:decision, :expander]

  defp valid_role_selector?(_role, _selector, _path), do: false

  defp valid_executable_evidence?(%{kind: :action, form: :module, module: module}),
    do: is_atom(module) and not is_nil(module)

  defp valid_executable_evidence?(%{kind: :flow, form: :module, module: module}),
    do: is_atom(module) and not is_nil(module)

  defp valid_executable_evidence?(%{kind: :flow, form: :value, module: nil}), do: true
  defp valid_executable_evidence?(_executable), do: false

  defp valid_output?(%Output{} = output), do: match?({:ok, %Output{}}, Output.validate(output))

  defp valid_output?(output) when is_map(output) do
    not is_struct(output) or is_nil(Enumerable.impl_for(output))
  end

  defp valid_output?(_output), do: false

  defp proper_list?(value), do: is_list(value) and not List.improper?(value)
  defp binary_or_nil?(value), do: is_binary(value) or is_nil(value)

  defp exact_shape?(map, keys),
    do: map_size(map) == length(keys) and Enum.all?(keys, &Map.has_key?(map, &1))

  defp invocation_id(%{id: id}), do: id
  defp invocation_id(_invocation), do: nil

  defp receipt_invocation_id(%{invocation: invocation}), do: invocation_id(invocation)
  defp receipt_invocation_id(_receipt), do: nil

  defp call(module, callback, args) do
    {:ok, apply(module, callback, args)}
  rescue
    exception -> {:error, exception, __STACKTRACE__}
  catch
    kind, reason -> {:error, %{kind: kind, reason: reason}, __STACKTRACE__}
  end

  defp callback_failure(stage, reason, invocation_id, stacktrace) do
    error = Error.interrupted_error(stage, reason, invocation_id)
    %{error | stacktrace: %Splode.Stacktrace{stacktrace: stacktrace}}
  end

  defp invalid(reason), do: {:error, {reason, %{}}}
end
