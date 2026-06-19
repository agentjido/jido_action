defmodule Jido.Flow.Switch do
  @moduledoc false

  alias Jido.Action.Error
  alias Jido.Flow
  alias Jido.Flow.Switch.Branch
  alias Jido.Flow.Validator

  @schema Zoi.struct(
            __MODULE__,
            %{
              name:
                Zoi.atom()
                |> Zoi.refine({Validator, :validate_component_name, []}),
              hash: Zoi.integer(description: "Runtime Runic node hash"),
              on: Zoi.any(description: "Switch input reference"),
              matches: Zoi.list(Zoi.map(), description: "Ordered switch matches"),
              default:
                Zoi.any(description: "Default switch target or branch") |> Zoi.default(nil),
              return?: Zoi.boolean(description: "Whether compact switch emits target values")
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc false
  @spec new(map()) :: t()
  def new(%{type: :switch} = entry) do
    validate_entry!(entry)

    attrs = %{
      name: entry.name,
      hash: switch_hash(entry),
      on: entry.on,
      matches: entry.matches,
      default: Map.get(entry, :default),
      return?: Map.get(entry, :return?, false)
    }

    parse_switch!(attrs)
  end

  defp validate_entry!(entry) do
    case Validator.validate_entry(entry, []) do
      :ok -> :ok
      {:error, reason} -> raise ArgumentError, "invalid flow switch: #{reason}"
    end
  end

  @doc false
  def select(%__MODULE__{} = switch, input_value, opts \\ []) do
    run_context = Keyword.get(opts, :run_context, %{})

    with {:ok, value} <- resolve_on(switch.on, input_value) do
      case select_match(switch.matches, value) do
        {:ok, match} ->
          resolve_match(switch, match, value, run_context)

        :default ->
          resolve_default(switch, value, run_context)
      end
    end
  end

  defp parse_switch!(attrs) do
    case Zoi.parse(@schema, attrs) do
      {:ok, switch} ->
        switch

      {:error, errors} ->
        raise ArgumentError, "invalid flow switch:\n" <> Zoi.prettify_errors(errors)
    end
  end

  defp switch_hash(entry) do
    :erlang.phash2({
      __MODULE__,
      entry.name,
      entry.on,
      entry.matches,
      Map.get(entry, :default),
      Map.get(entry, :return?, false)
    })
  end

  defp select_match(matches, value) do
    Enum.find_value(matches, :default, fn match ->
      if apply_callable(match.predicate, [value]) do
        {:ok, match}
      end
    end)
  end

  defp resolve_match(%__MODULE__{} = switch, match, value, run_context) do
    if Branch.flow?(match) do
      run_branch(match, value, run_context)
    else
      resolve_compact_match(switch, match, value)
    end
  end

  defp resolve_compact_match(%__MODULE__{} = switch, %{then: target}, value),
    do: resolve_compact_value(switch, target, value)

  defp resolve_default(%__MODULE__{default: default} = switch, value, run_context)
       when is_map(default) do
    if Branch.default?(default) do
      run_branch(default, value, run_context)
    else
      resolve_compact_value(switch, default, value)
    end
  end

  defp resolve_default(%__MODULE__{} = switch, value, _run_context),
    do: resolve_compact_value(switch, switch.default, value)

  defp resolve_compact_value(%__MODULE__{return?: true}, compact_value, _input_value),
    do: {:ok, compact_value}

  defp resolve_compact_value(%__MODULE__{return?: false}, _compact_value, input_value),
    do: {:ok, input_value}

  defp run_branch(branch, value, run_context) do
    flow =
      Flow.new(%{
        name: branch_name(branch),
        flow: Map.get(branch, :flow, []),
        return: Map.get(branch, :return)
      })

    case Jido.Exec.run(flow, value, run_context: run_context || %{}) do
      {:ok, result} ->
        branch_result(result, Map.get(branch, :return), value)

      {:error, %Jido.Exec.Result{} = result} ->
        {:error,
         Error.execution_error("switch branch failed", %{
           status: result.status,
           error: result.error
         })}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp branch_name(%{name: name}) when is_atom(name) and not is_nil(name), do: name
  defp branch_name(_branch), do: :switch_default

  defp branch_result(result, nil, _input), do: {:ok, Jido.Exec.results(result)}

  defp branch_result(result, return_ref, input) do
    result
    |> Jido.Exec.results()
    |> resolve_return(return_ref, input)
  end

  defp resolve_return(results, {:result, name}, _input) when is_map(results) do
    fetch_result(results, name)
  end

  defp resolve_return(results, {:result, name, path}, _input) when is_map(results) do
    with {:ok, value} <- fetch_result(results, name),
         {:ok, selected} <- fetch_path(value, path) do
      {:ok, selected}
    else
      :error -> {:error, missing_return_path(name, path)}
    end
  end

  defp resolve_return(_results, {:input, name}, input) when is_map(input) do
    case Map.fetch(input, name) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, missing_input(name)}
    end
  end

  defp resolve_return(_results, {:value, value}, _input), do: {:ok, value}

  defp resolve_return(_results, return_ref, _input) do
    {:error,
     Error.execution_error("unsupported switch branch return", %{
       return: return_ref
     })}
  end

  defp fetch_result(results, name) do
    case Map.fetch(results, name) do
      {:ok, [value]} -> {:ok, value}
      {:ok, values} when is_list(values) and values != [] -> {:ok, List.last(values)}
      {:ok, value} -> {:ok, value}
      :error -> {:error, missing_result(name)}
    end
  end

  defp resolve_on({:input, name}, input) when is_map(input) do
    case Map.fetch(input, name) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, missing_input(name)}
    end
  end

  defp resolve_on({:input, name}, _input), do: {:error, missing_input(name)}
  defp resolve_on({:result, _name}, input), do: {:ok, input}

  defp resolve_on({:result, name, path}, input) do
    case fetch_path(input, path) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, missing_return_path(name, path)}
    end
  end

  defp resolve_on({:value, value}, _input), do: {:ok, value}

  defp resolve_on(other, _input) do
    {:error,
     Error.execution_error("unsupported switch input reference", %{
       on: other
     })}
  end

  defp fetch_path(value, []), do: {:ok, value}

  defp fetch_path(%{} = value, [key | rest]) when is_atom(key) do
    case Map.fetch(value, key) do
      {:ok, next} -> fetch_path(next, rest)
      :error -> :error
    end
  end

  defp fetch_path(value, [index | rest]) when is_list(value) and is_integer(index) do
    case Enum.fetch(value, index) do
      {:ok, next} -> fetch_path(next, rest)
      :error -> :error
    end
  end

  defp fetch_path(_value, _path), do: :error

  defp missing_input(name) do
    Error.execution_error("switch input #{inspect(name)} not found", %{input: name})
  end

  defp missing_result(name) do
    Error.execution_error("switch branch result #{inspect(name)} not found", %{result: name})
  end

  defp missing_return_path(name, path) do
    Error.execution_error("switch path #{inspect(path)} not found", %{result: name, path: path})
  end

  defp apply_callable({module, function}, args), do: apply(module, function, args)
  defp apply_callable({:mfa, module, function}, args), do: apply(module, function, args)
end

defimpl Runic.Workflow.Invokable, for: Jido.Flow.Switch do
  alias Runic.Workflow
  alias Runic.Workflow.Events.{ActivationConsumed, FactProduced}
  alias Runic.Workflow.{CausalContext, Fact, Runnable}

  def match_or_execute(_switch), do: :execute

  def invoke(%Jido.Flow.Switch{} = switch, %Workflow{} = workflow, %Fact{} = fact) do
    with {:ok, runnable} <- prepare(switch, workflow, fact) do
      workflow
      |> Workflow.apply_runnable(execute(switch, runnable))
    end
  end

  def prepare(%Jido.Flow.Switch{} = switch, %Workflow{} = workflow, %Fact{} = fact) do
    context =
      CausalContext.new(
        node_hash: switch.hash,
        input_fact: fact,
        ancestry_depth: Workflow.ancestry_depth(workflow, fact),
        run_context: Workflow.get_run_context(workflow, switch.name)
      )

    {:ok, Runnable.new(switch, fact, context)}
  end

  def execute(%Jido.Flow.Switch{} = switch, %Runnable{input_fact: fact} = runnable) do
    case Jido.Flow.Switch.select(switch, fact.value, run_context: run_context(runnable)) do
      {:ok, value} ->
        complete(runnable, switch, fact, value)

      {:error, reason} ->
        Runnable.fail(runnable, reason)
    end
  rescue
    error ->
      Runnable.fail(
        runnable,
        Jido.Action.Error.execution_error("switch evaluation raised", %{
          switch: switch.name,
          reason: error,
          stacktrace: __STACKTRACE__
        })
      )
  end

  defp complete(%Runnable{} = runnable, switch, %Fact{} = input_fact, value) do
    result_fact = Fact.new(value: value, ancestry: {switch.hash, input_fact.hash})
    Runnable.complete(runnable, result_fact, events(switch, input_fact, result_fact, runnable))
  end

  defp events(switch, %Fact{} = input_fact, %Fact{} = result_fact, %Runnable{} = runnable) do
    [
      %FactProduced{
        hash: result_fact.hash,
        value: result_fact.value,
        ancestry: result_fact.ancestry,
        producer_label: :produced,
        weight: ancestry_depth(runnable) + 1,
        meta: result_fact.meta
      },
      %ActivationConsumed{
        fact_hash: input_fact.hash,
        node_hash: switch.hash,
        from_label: :runnable
      }
    ]
  end

  defp ancestry_depth(%Runnable{context: %{ancestry_depth: depth}}) when is_integer(depth),
    do: depth

  defp ancestry_depth(_runnable), do: 0

  defp run_context(%Runnable{context: %{run_context: context}}) when is_map(context), do: context
  defp run_context(_runnable), do: %{}
end

defimpl Runic.Component, for: Jido.Flow.Switch do
  alias Runic.Workflow

  def connectable?(_switch, _other), do: true

  def connect(switch, to, workflow) when is_list(to) do
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
    |> Workflow.add_step(join, switch)
    |> Workflow.draw_connection(switch, switch, :component_of, properties: %{kind: :flow_switch})
    |> Workflow.register_component(switch)
  end

  def connect(switch, to, workflow) do
    workflow
    |> Workflow.add_step(to, switch)
    |> Workflow.draw_connection(switch, switch, :component_of, properties: %{kind: :flow_switch})
    |> Workflow.register_component(switch)
  end

  def source(switch) do
    quote do
      Jido.Flow.Switch.new(%{
        type: :switch,
        name: unquote(switch.name),
        on: unquote(Macro.escape(switch.on)),
        matches: unquote(Macro.escape(switch.matches)),
        default: unquote(Macro.escape(switch.default)),
        return?: unquote(switch.return?)
      })
    end
  end

  def hash(switch), do: switch.hash
  def inputs(_switch), do: [input: [type: :any, doc: "Switch input"]]
  def outputs(_switch), do: [output: [type: :any, doc: "Switch output"]]
end

defimpl Runic.Transmutable, for: Jido.Flow.Switch do
  alias Runic.Workflow

  def transmute(switch), do: to_workflow(switch)

  def to_workflow(%Jido.Flow.Switch{} = switch) do
    Workflow.new(name: switch.name)
    |> Workflow.add(switch)
  end

  def to_component(switch), do: switch
end
