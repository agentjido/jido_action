defmodule Jido.Flow.Step do
  @moduledoc """
  Internal workflow step that wraps one Jido action invocation.

  `Jido.Flow.Step` is the bridge between explicit `Jido.Flow` composition and
  the leaf-action execution boundary. It participates in Runic's
  prepare/execute/apply lifecycle, but the actual action call only invokes one
  action attempt. Retry, timeout, and fallback policy belong to Runic's
  scheduler.
  """

  alias Jido.Exec.Validator
  alias Jido.Instruction

  @schema Zoi.struct(
            __MODULE__,
            %{
              name:
                Zoi.union([
                  Zoi.atom(),
                  Zoi.string()
                ])
                |> Zoi.refine({__MODULE__, :validate_name, []}),
              hash: Zoi.integer(description: "Stable flow step hash"),
              instruction: Zoi.struct(Instruction, description: "Normalized action invocation"),
              action:
                Zoi.atom(description: "Action module to execute")
                |> Zoi.refine({Instruction, :validate_action_module, []}),
              params: Zoi.map(description: "Static action parameters"),
              context: Zoi.map(description: "Static action context"),
              exec_opts:
                Zoi.keyword(Zoi.any(), description: "Execution options")
                |> Zoi.default([]),
              inputs:
                Zoi.keyword(Zoi.any(), description: "Runic input ports")
                |> Zoi.default([]),
              outputs:
                Zoi.keyword(Zoi.any(), description: "Runic output ports")
                |> Zoi.default([])
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc false
  @spec validate_name(term(), keyword()) :: :ok | {:error, String.t()}
  def validate_name(value, _opts \\ [])
  def validate_name(value, _opts) when is_atom(value) and not is_nil(value), do: :ok
  def validate_name(value, _opts) when is_binary(value) and value != "", do: :ok
  def validate_name(value, _opts) when is_atom(value), do: {:error, "cannot be nil"}
  def validate_name(value, _opts) when is_binary(value), do: {:error, "cannot be empty"}
  def validate_name(_value, _opts), do: {:error, "must be an atom or string"}

  @doc """
  Creates a flow step from an action module or `%Jido.Instruction{}`.

  Options:

  - `:name` - step name. Defaults to the action module's last segment.
  - `:context` - static action context. Runtime context can still be supplied by
    `Jido.Exec`.
  - `:exec_opts` - options used for the one-shot action invocation and Runic
    scheduler policy derivation.
  - any remaining options are also treated as execution options.
  """
  @spec new(module() | Instruction.t(), map() | keyword(), keyword()) :: t()
  def new(action_or_instruction, params \\ %{}, opts \\ []) when is_list(opts) do
    params = normalize_map!(params, :params)

    {name, opts} = Keyword.pop(opts, :name)
    {context, opts} = Keyword.pop(opts, :context, %{})
    {explicit_exec_opts, opts} = Keyword.pop(opts, :exec_opts, [])

    context = normalize_map!(context, :context)
    exec_opts = Keyword.merge(opts, normalize_opts!(explicit_exec_opts, :exec_opts))
    instruction = build_instruction!(action_or_instruction, params, context, exec_opts)
    validate_action!(instruction.action)
    name = name || derive_name(instruction.action)

    %{
      name: name,
      hash: step_hash(instruction, name),
      instruction: instruction,
      action: instruction.action,
      params: instruction.params,
      context: instruction.context,
      exec_opts: instruction.opts,
      inputs: derive_inputs(instruction.action),
      outputs: derive_outputs(instruction.action)
    }
    |> parse_step!()
  end

  defp parse_step!(attrs) do
    case Zoi.parse(@schema, attrs) do
      {:ok, step} ->
        step

      {:error, errors} ->
        raise ArgumentError, "invalid flow step:\n" <> Zoi.prettify_errors(errors)
    end
  end

  defp build_instruction!(%Instruction{} = instruction, params, context, exec_opts) do
    Instruction.new!(%{
      id: instruction.id,
      action: instruction.action,
      params: Map.merge(normalize_map!(instruction.params || %{}, :params), params),
      context: Map.merge(normalize_map!(instruction.context || %{}, :context), context),
      opts: Keyword.merge(normalize_opts!(instruction.opts || [], :opts), exec_opts)
    })
  end

  defp build_instruction!(action, params, context, exec_opts)
       when is_atom(action) and not is_nil(action) do
    Instruction.new!(%{
      action: action,
      params: params,
      context: context,
      opts: exec_opts
    })
  end

  defp build_instruction!(other, _params, _context, _exec_opts) do
    raise ArgumentError,
          "expected an action module or %Jido.Instruction{}, got: #{inspect(other)}"
  end

  defp validate_action!(action) do
    with :ok <- Validator.validate_action(action),
         true <- function_exported?(action, :validate_params, 1),
         true <- function_exported?(action, :validate_output, 1) do
      :ok
    else
      {:error, error} ->
        raise ArgumentError, Exception.message(error)

      false ->
        raise ArgumentError,
              "Module #{inspect(action)} is not a valid Jido action: missing validation functions"
    end
  end

  defp derive_name(action) do
    action
    |> Module.split()
    |> List.last()
    |> Macro.underscore()
    |> String.to_atom()
  end

  defp step_hash(%Instruction{} = instruction, name) do
    :erlang.phash2({
      __MODULE__,
      name,
      instruction.action,
      instruction.params,
      instruction.context,
      instruction.opts
    })
  end

  defp derive_inputs(action),
    do: derive_ports(action, :schema, :input, "Input to the action", :input)

  defp derive_outputs(action),
    do: derive_ports(action, :output_schema, :result, "Action result", :output)

  defp derive_ports(action, schema_fun, default_name, default_doc, direction) do
    if function_exported?(action, schema_fun, 0) do
      action
      |> apply(schema_fun, [])
      |> schema_ports(default_name, default_doc, direction)
    else
      default_ports(default_name, default_doc)
    end
  end

  defp schema_ports(schema, default_name, default_doc, direction) do
    case port_keys(schema, direction) do
      [] ->
        default_ports(default_name, default_doc)

      keys ->
        Enum.map(keys, fn key ->
          {key, [type: :any, doc: Atom.to_string(key)]}
        end)
    end
  rescue
    _ -> default_ports(default_name, default_doc)
  end

  defp port_keys(schema, :output), do: schema_keys(schema)

  defp port_keys(%{__struct__: struct, fields: fields}, :input)
       when struct in [Zoi.Types.Map, Zoi.Types.Struct] and is_list(fields) do
    fields
    |> Enum.reject(fn {_key, field_schema} -> optional_input_port?(field_schema) end)
    |> Keyword.keys()
  end

  defp port_keys(%{__struct__: struct, fields: fields}, :input)
       when struct in [Zoi.Types.Map, Zoi.Types.Struct] and is_map(fields) do
    fields
    |> Enum.reject(fn {_key, field_schema} -> optional_input_port?(field_schema) end)
    |> Enum.map(fn {key, _field_schema} -> key end)
  end

  defp port_keys(schema, :input), do: schema_keys(schema)

  defp optional_input_port?(%{__struct__: Zoi.Types.Default}), do: true
  defp optional_input_port?(%{meta: %{required: false}}), do: true
  defp optional_input_port?(_schema), do: false

  defp schema_keys([]), do: []

  defp schema_keys(%{__struct__: struct, fields: fields})
       when struct in [Zoi.Types.Map, Zoi.Types.Struct] and is_list(fields),
       do: Keyword.keys(fields)

  defp schema_keys(%{__struct__: struct, fields: fields})
       when struct in [Zoi.Types.Map, Zoi.Types.Struct] and is_map(fields),
       do: Map.keys(fields)

  defp schema_keys(_schema), do: []

  defp default_ports(name, doc), do: [{name, [type: :any, doc: doc]}]

  defp normalize_map!(nil, _field), do: %{}
  defp normalize_map!(value, _field) when is_map(value), do: value

  defp normalize_map!(value, _field) when is_list(value) do
    if Keyword.keyword?(value) do
      Map.new(value)
    else
      raise ArgumentError, "expected a map or keyword list, got: #{inspect(value)}"
    end
  end

  defp normalize_map!(value, field) do
    raise ArgumentError, "expected #{field} to be a map or keyword list, got: #{inspect(value)}"
  end

  defp normalize_opts!(nil, _field), do: []

  defp normalize_opts!(value, _field) when is_list(value) do
    if Keyword.keyword?(value) do
      value
    else
      raise ArgumentError, "expected a keyword list, got: #{inspect(value)}"
    end
  end

  defp normalize_opts!(value, field) do
    raise ArgumentError, "expected #{field} to be a keyword list, got: #{inspect(value)}"
  end
end

defimpl Runic.Workflow.Invokable, for: Jido.Flow.Step do
  alias Runic.Workflow
  alias Runic.Workflow.Events.{ActivationConsumed, FactProduced}
  alias Runic.Workflow.{CausalContext, Fact, Runnable}

  def match_or_execute(_step), do: :execute

  def invoke(%Jido.Flow.Step{} = step, %Workflow{} = workflow, %Fact{} = fact) do
    with {:ok, runnable} <- prepare(step, workflow, fact) do
      workflow
      |> Workflow.apply_runnable(execute(step, runnable))
    end
  end

  def prepare(%Jido.Flow.Step{} = step, %Workflow{} = workflow, %Fact{} = fact) do
    context =
      CausalContext.new(
        node_hash: step.hash,
        input_fact: fact,
        ancestry_depth: Workflow.ancestry_depth(workflow, fact),
        run_context: Workflow.get_run_context(workflow, step.name)
      )

    {:ok, Runnable.new(step, fact, context)}
  end

  def execute(%Jido.Flow.Step{} = step, %Runnable{input_fact: fact} = runnable) do
    params =
      Map.merge(step.params, fact_params(fact.value), fn _key, _static, runtime -> runtime end)

    context = Map.merge(step.context, run_context(runnable))

    case Jido.Exec.invoke_action_once(step.action, params, context, step.exec_opts) do
      {:ok, result} ->
        complete(runnable, step, fact, result)

      {:ok, result, extra} ->
        complete(runnable, step, fact, %{result: result, extra: extra})

      {:error, reason} ->
        Runnable.fail(runnable, reason)

      {:error, reason, extra} ->
        Runnable.fail(runnable, {reason, extra})
    end
  end

  defp complete(%Runnable{} = runnable, step, %Fact{} = input_fact, value) do
    result_fact = Fact.new(value: value, ancestry: {step.hash, input_fact.hash})
    Runnable.complete(runnable, result_fact, events(step, input_fact, result_fact, runnable))
  end

  defp events(step, %Fact{} = input_fact, %Fact{} = result_fact, %Runnable{} = runnable) do
    [
      %FactProduced{
        hash: result_fact.hash,
        value: result_fact.value,
        ancestry: result_fact.ancestry,
        producer_label: :produced,
        weight: ancestry_depth(runnable) + 1
      },
      %ActivationConsumed{
        fact_hash: input_fact.hash,
        node_hash: step.hash,
        from_label: :runnable
      }
    ]
  end

  defp ancestry_depth(%Runnable{context: %{ancestry_depth: depth}}) when is_integer(depth),
    do: depth

  defp ancestry_depth(_runnable), do: 0

  defp run_context(%Runnable{context: %{run_context: context}}) when is_map(context), do: context
  defp run_context(_runnable), do: %{}

  defp fact_params(value) when is_map(value), do: value
  defp fact_params(value), do: %{input: value}
end

defimpl Runic.Component, for: Jido.Flow.Step do
  alias Runic.Workflow

  def connectable?(_step, _other), do: true

  def connect(step, to, workflow) when is_list(to) do
    join =
      to
      |> Enum.map(fn
        %{hash: hash} -> hash
        other -> other
      end)
      |> Runic.Workflow.Join.new()

    workflow
    |> then(fn wrk ->
      Enum.reduce(to, wrk, fn parent, acc -> Workflow.add_step(acc, parent, join) end)
    end)
    |> Workflow.add_step(join, step)
    |> Workflow.draw_connection(step, step, :component_of, properties: %{kind: :flow_step})
    |> Workflow.register_component(step)
  end

  def connect(step, to, workflow) do
    workflow
    |> Workflow.add_step(to, step)
    |> Workflow.draw_connection(step, step, :component_of, properties: %{kind: :flow_step})
    |> Workflow.register_component(step)
  end

  def source(step) do
    quote do
      Jido.Flow.Step.new(
        unquote(step.action),
        unquote(Macro.escape(step.params)),
        name: unquote(step.name),
        context: unquote(Macro.escape(step.context)),
        exec_opts: unquote(Macro.escape(step.exec_opts))
      )
    end
  end

  def hash(step), do: step.hash
  def inputs(%Jido.Flow.Step{inputs: inputs}), do: inputs
  def outputs(%Jido.Flow.Step{outputs: outputs}), do: outputs
end

defimpl Runic.Transmutable, for: Jido.Flow.Step do
  alias Runic.Workflow

  def transmute(step), do: to_workflow(step)

  def to_workflow(%Jido.Flow.Step{} = step) do
    Workflow.new(name: step.name)
    |> Workflow.add(step)
  end

  def to_component(step), do: step
end
