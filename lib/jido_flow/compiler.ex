defmodule Jido.Flow.Compiler do
  @moduledoc """
  Compiles canonical Flow artifacts into Runic workflows.
  """

  alias Jido.Action.Error
  alias Jido.Action.Output
  alias Jido.Exec
  alias Jido.Flow
  alias Jido.Flow.Choice
  alias Jido.Flow.Condition
  alias Jido.Flow.Element
  alias Jido.Flow.Identity
  alias Jido.Flow.Map, as: FlowMap
  alias Jido.Flow.Node
  alias Jido.Flow.NodeError
  alias Jido.Flow.Reduce
  alias Jido.Flow.Ref
  alias Runic.Workflow
  alias Runic.Workflow.Step

  @collector_key :__jido_flow_error_collector__
  @run_option_keys [:async, :max_concurrency]

  @type node_state :: %{
          flow: String.t(),
          flow_digest: String.t() | nil,
          input: map(),
          context: map(),
          results: map(),
          options: keyword(),
          map_nodes: MapSet.t(String.t())
        }

  @doc """
  Compiles a Flow artifact into a shape-accurate Runic workflow.

  The returned workflow is suitable for graph inspection. Runtime input and
  context are only available through `run/3`.
  """
  @spec compile(Flow.t()) :: {:ok, Workflow.t()} | {:error, Exception.t()}
  def compile(%Flow{} = flow) do
    with {:ok, flow} <- Flow.validate(flow),
         flow_digest = Identity.semantic_digest(flow),
         {:ok, workflow, _ordered_nodes} <- build(flow, {:inspection, flow_digest}) do
      {:ok, workflow}
    end
  end

  @doc false
  @spec runtime_workflow(Flow.t(), map(), map()) ::
          {:ok, Workflow.t()} | {:error, Exception.t()}
  def runtime_workflow(%Flow{} = flow, input, context)
      when is_map(input) and is_map(context) do
    with {:ok, _flow, workflow, _ordered_nodes} <- prepare_runtime(flow, input, context, nil) do
      {:ok, workflow}
    end
  end

  def runtime_workflow(%Flow{}, _input, _context) do
    {:error, Error.validation_error("flow input and context must be maps")}
  end

  @doc false
  @spec runtime_workflow_validated(Flow.t(), map(), map()) ::
          {:ok, Workflow.t(), [Element.t()]} | {:error, Exception.t()}
  def runtime_workflow_validated(%Flow{} = flow, input, context)
      when is_map(input) and is_map(context) do
    prepare_validated_runtime(flow, input, context, nil, normalize_runtime_options([]))
  end

  def runtime_workflow_validated(%Flow{}, _input, _context) do
    {:error, Error.validation_error("flow input and context must be maps")}
  end

  @doc false
  @spec runtime_workflow_validated(Flow.t(), map(), map(), keyword()) ::
          {:ok, Workflow.t(), [Element.t()]} | {:error, Exception.t()}
  def runtime_workflow_validated(%Flow{} = flow, input, context, options)
      when is_map(input) and is_map(context) and is_list(options) do
    prepare_validated_runtime(flow, input, context, nil, options)
  end

  def runtime_workflow_validated(%Flow{}, _input, _context, _options) do
    {:error, Error.validation_error("flow input and context must be maps")}
  end

  @doc false
  @spec runtime_result(Flow.t(), Workflow.t(), map(), map()) ::
          {:ok, term()} | {:error, Exception.t()}
  def runtime_result(%Flow{} = flow, %Workflow{} = workflow, input, context)
      when is_map(input) and is_map(context) do
    extract_return(flow.return, workflow, input, context)
  end

  @doc """
  Compiles and executes a Flow artifact, returning its declared return value.

  Accepted runtime options are `:async` and `:max_concurrency`, which are passed
  through to Runic workflow reaction.
  """
  @spec run(Flow.t(), map(), map(), keyword()) :: {:ok, term()} | {:error, Exception.t()}
  def run(flow, input, context \\ %{}, opts \\ [])

  def run(%Flow{} = flow, input, context, opts) when is_map(input) and is_map(context) do
    with :ok <- validate_run_opts(opts),
         {:ok, flow} <- Flow.validate(flow),
         :ok <- Flow.check(flow) do
      execute(flow, input, context, opts)
    end
  end

  def run(%Flow{}, _input, _context, _opts) do
    {:error, Error.validation_error("flow input and context must be maps")}
  end

  @doc false
  @spec run_validated(Flow.t(), map(), map(), keyword()) ::
          {:ok, term()} | {:error, Exception.t()}
  def run_validated(%Flow{} = flow, input, context, opts)
      when is_map(input) and is_map(context) and is_list(opts) do
    execute(flow, input, context, opts)
  end

  defp execute(flow, input, context, opts) do
    runner = self()
    run_ref = make_ref()

    with {:ok, workflow, ordered_nodes} <-
           prepare_validated_runtime(
             flow,
             input,
             context,
             {runner, run_ref},
             normalize_runtime_options(opts)
           ) do
      final_workflow = Workflow.react_until_satisfied(workflow, input, opts)
      node_errors = drain_node_errors(run_ref, ordered_nodes)

      case node_errors do
        [{_node, error} | _rest] ->
          {:error, error}

        [] ->
          extract_return(flow.return, final_workflow, input, context)
      end
    end
  end

  defp validate_run_opts(opts) when is_list(opts) do
    if Keyword.keyword?(opts) do
      with :ok <- validate_known_run_opts(opts),
           :ok <- validate_async_opt(Keyword.get(opts, :async, false)),
           :ok <- validate_max_concurrency_opt(Keyword.get(opts, :max_concurrency, 1)) do
        :ok
      end
    else
      {:error, Error.validation_error("run options must be a keyword list")}
    end
  end

  defp validate_run_opts(_opts) do
    {:error, Error.validation_error("run options must be a keyword list")}
  end

  defp validate_known_run_opts(opts) do
    opts
    |> Keyword.keys()
    |> Enum.find(&(&1 not in @run_option_keys))
    |> case do
      nil ->
        :ok

      option ->
        {:error,
         Error.validation_error("unknown run option: #{inspect(option)}", %{option: option})}
    end
  end

  defp validate_async_opt(async) when is_boolean(async), do: :ok

  defp validate_async_opt(_async) do
    {:error, Error.validation_error("async option must be a boolean", %{option: :async})}
  end

  defp validate_max_concurrency_opt(max_concurrency)
       when is_integer(max_concurrency) and max_concurrency > 0,
       do: :ok

  defp validate_max_concurrency_opt(_max_concurrency) do
    {:error,
     Error.validation_error("max_concurrency option must be a positive integer", %{
       option: :max_concurrency
     })}
  end

  defp prepare_runtime(flow, input, context, collector) do
    with {:ok, flow} <- Flow.validate(flow),
         :ok <- Flow.check(flow),
         {:ok, workflow, ordered_nodes} <-
           prepare_validated_runtime(
             flow,
             input,
             context,
             collector,
             normalize_runtime_options([])
           ) do
      {:ok, flow, workflow, ordered_nodes}
    end
  end

  defp prepare_validated_runtime(flow, input, context, collector, options) do
    collection_elements = Enum.filter(flow.nodes, &collection_element?/1)

    node_state =
      %{
        flow: flow.name,
        flow_digest: if(collection_elements == [], do: nil, else: Identity.semantic_digest(flow)),
        input: input,
        context: context,
        results: %{},
        options: options,
        map_nodes:
          collection_elements
          |> Enum.filter(&match?(%FlowMap{}, &1))
          |> MapSet.new(&Element.name/1)
      }
      |> Map.put(@collector_key, collector)

    build(flow, {:runtime, node_state})
  end

  defp build(%Flow{} = flow, mode) do
    nodes_by_name = Map.new(flow.nodes, fn node -> {Element.name(node), node} end)

    {workflow, _added, ordered} =
      flow.nodes
      |> Flow.canonical_nodes()
      |> Enum.reduce({Workflow.new(flow.name), MapSet.new(), []}, fn node,
                                                                     {workflow, added, ordered} ->
        add_node(Element.name(node), nodes_by_name, workflow, added, ordered, mode)
      end)

    {:ok, workflow, ordered}
  end

  defp add_node(name, nodes_by_name, workflow, added, ordered, mode) do
    if MapSet.member?(added, name) do
      {workflow, added, ordered}
    else
      node = Map.fetch!(nodes_by_name, name)

      {workflow, added, ordered} =
        add_dependencies(Element.deps(node), nodes_by_name, workflow, added, ordered, mode)

      step = build_step(node, mode)

      workflow = add_step(workflow, node, step)

      {workflow, MapSet.put(added, name), ordered ++ [node]}
    end
  end

  defp add_dependencies([], _nodes_by_name, workflow, added, ordered, _mode) do
    {workflow, added, ordered}
  end

  defp add_dependencies(
         [dep | deps],
         nodes_by_name,
         workflow,
         added,
         ordered,
         mode
       ) do
    {workflow, added, ordered} =
      add_node(dep, nodes_by_name, workflow, added, ordered, mode)

    add_dependencies(deps, nodes_by_name, workflow, added, ordered, mode)
  end

  defp build_step(node, {:inspection, flow_digest}) do
    name = Element.name(node)

    Step.new(
      name: name,
      hash: Identity.step_uuid(flow_digest, name),
      work: fn _parent_value -> {:jido_flow_node, 1, name} end
    )
  end

  defp build_step(node, {:runtime, node_state}) do
    Step.new(
      name: node.name,
      work: fn parent_value -> run_node(node, parent_value, node_state) end
    )
  end

  defp add_step(workflow, element, step) do
    case Element.deps(element) do
      [] -> Workflow.add(workflow, step, validate: :off)
      [dep] -> Workflow.add(workflow, step, to: dep, validate: :off)
      deps -> Workflow.add(workflow, step, to: deps, validate: :off)
    end
  end

  defp run_node(node, parent_value, node_state) do
    metadata = node_metadata(node, node_state)

    result =
      :telemetry.span([:jido, :flow, :node], metadata, fn ->
        result = run_node_result(node, parent_value, node_state)
        {result, Map.merge(metadata, node_result_metadata(result))}
      end)

    case result do
      {:ok, output} -> output
      {:ok, output, _choice_metadata} -> output
      {:error, error, state} -> raise_node_error(node, error, state)
      {:error, error, state, _choice_metadata} -> raise_node_error(node, error, state)
    end
  end

  defp run_node_result(%Choice{} = choice, parent_value, node_state) do
    state = %{node_state | results: dependency_results(choice, parent_value)}

    case select_choice_target(choice, state) do
      {:ok, target} ->
        metadata = %{option: target.name, target: target.action}

        with {:ok, params} <- resolve_expr(target.input, state),
             {:ok, output} <-
               run_resolved_target(
                 target.action,
                 params,
                 state.context,
                 choice_target_owner(choice, target)
               ) do
          {:ok, output, metadata}
        else
          {:error, error} -> {:error, error, state, metadata}
        end

      {:error, error} ->
        {:error, error, state}
    end
  end

  defp run_node_result(%FlowMap{} = map, parent_value, node_state) do
    state = %{node_state | results: dependency_results(map, parent_value)}

    case resolve_expr(map.collection, state) do
      {:ok, collection} -> run_resolved_map(map, collection, state)
      {:error, error} -> {:error, error, state, map_metadata(map, 0, 0, 0)}
    end
  end

  defp run_node_result(%Reduce{} = reduce, parent_value, node_state) do
    state = %{node_state | results: dependency_results(reduce, parent_value)}

    case resolve_expr(reduce.collection, state) do
      {:ok, collection} -> run_resolved_reduce(reduce, collection, state)
      {:error, error} -> {:error, error, state, reduce_metadata(reduce, 0, 0)}
    end
  end

  defp run_node_result(node, parent_value, node_state) do
    state = %{node_state | results: dependency_results(node, parent_value)}

    case resolve_expr(node.input, state) do
      {:ok, params} ->
        case run_resolved_node(node, params, state.context) do
          {:ok, output} -> {:ok, output}
          {:error, error} -> {:error, error, state}
        end

      {:error, error} ->
        {:error, error, state}
    end
  end

  defp run_resolved_node(node, params, context) do
    run_resolved_target(node.action, params, context, node_target_owner(node))
  end

  defp run_resolved_map(map, collection, state) do
    if is_list(collection) and not List.improper?(collection) do
      items =
        collection
        |> Enum.with_index()
        |> Enum.map(fn {item, index} ->
          %{
            item: item,
            item_index: index,
            item_id: Identity.item_uuid(state.flow_digest, map.name, index)
          }
        end)

      case dispatch_map_items(map, items, state) do
        {:ok, results, errors} ->
          aggregate = %{kind: :jido_flow_map_result, results: results, errors: errors}
          {:ok, aggregate, map_metadata(map, length(items), length(results), length(errors))}

        {:error, error, started_count, success_count, error_count} ->
          {:error, error, state, map_metadata(map, started_count, success_count, error_count)}
      end
    else
      error =
        Error.execution_error("map collection must resolve to a proper list", %{
          phase: :map_collection,
          node: map.name,
          reason: :not_a_proper_list,
          value_type: value_type(collection),
          retry: false
        })

      {:error, error, state, map_metadata(map, 0, 0, 0)}
    end
  end

  defp run_resolved_reduce(reduce, collection, state) do
    with {:ok, items} <- normalize_reduce_collection(reduce, collection, state),
         {:ok, initial} <- resolve_expr(reduce.initial, state),
         {:ok, initial} <- validate_reduce_initial(reduce, initial) do
      fold_reduce_items(reduce, items, initial, state)
    else
      {:error, error} -> {:error, error, state, reduce_metadata(reduce, 0, 0)}
    end
  end

  defp normalize_reduce_collection(reduce, collection, state) do
    if direct_map_source?(reduce.collection, state.map_nodes) do
      normalize_direct_map_result(reduce, collection)
    else
      normalize_reduce_list(reduce, collection, state.flow_digest)
    end
  end

  defp direct_map_source?(%Ref{type: :result, node: node, path: []}, map_nodes) do
    MapSet.member?(map_nodes, node)
  end

  defp direct_map_source?(_collection, _map_nodes), do: false

  defp normalize_reduce_list(reduce, collection, flow_digest) do
    if is_list(collection) and not List.improper?(collection) do
      items =
        collection
        |> Enum.with_index()
        |> Enum.map(fn {item, index} ->
          %{
            item: item,
            item_index: index,
            item_id: Identity.item_uuid(flow_digest, reduce.name, index)
          }
        end)

      {:ok, items}
    else
      {:error,
       Error.execution_error("reduce collection must resolve to a proper list", %{
         phase: :reduce_collection,
         node: reduce.name,
         reason: :not_a_proper_list,
         value_type: value_type(collection),
         retry: false
       })}
    end
  end

  defp normalize_direct_map_result(
         reduce,
         %{kind: :jido_flow_map_result, results: results, errors: errors} = aggregate
       ) do
    with :ok <- validate_direct_map_keys(aggregate),
         :ok <- validate_direct_map_records(results, errors) do
      if errors == [] do
        {:ok,
         Enum.map(results, fn result ->
           %{item: result.output, item_index: result.index, item_id: result.item_id}
         end)}
      else
        {:error,
         Error.execution_error("reduce cannot consume a Map result with errors", %{
           phase: :reduce_collection,
           node: reduce.name,
           reason: :map_errors_present,
           error_indices: Enum.map(errors, & &1.index),
           retry: false
         })}
      end
    else
      {:error, path} -> invalid_direct_map_result(reduce, path)
    end
  end

  defp normalize_direct_map_result(reduce, _collection),
    do: invalid_direct_map_result(reduce, [])

  defp validate_direct_map_keys(aggregate) do
    if aggregate |> Map.keys() |> MapSet.new() ==
         MapSet.new([:kind, :results, :errors]) do
      :ok
    else
      {:error, []}
    end
  end

  defp validate_direct_map_records(results, errors) do
    with true <- is_list(results) and not List.improper?(results),
         true <- is_list(errors) and not List.improper?(errors),
         :ok <- validate_direct_records(results, :result, [:results]),
         :ok <- validate_direct_records(errors, :error, [:errors]),
         :ok <- validate_direct_record_identity(results, errors) do
      :ok
    else
      false -> {:error, []}
      {:error, path} -> {:error, path}
    end
  end

  defp validate_direct_records(records, kind, root_path) do
    records
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, -1}, fn {record, position}, {:ok, previous_index} ->
      case validate_direct_record(record, kind, previous_index) do
        {:ok, index} -> {:cont, {:ok, index}}
        :error -> {:halt, {:error, root_path ++ [position]}}
      end
    end)
    |> case do
      {:ok, _last_index} -> :ok
      {:error, path} -> {:error, path}
    end
  end

  defp validate_direct_record(record, kind, previous_index) when is_map(record) do
    index = Map.get(record, :index)

    if valid_direct_record_keys?(record, kind) and valid_direct_record_value?(record, kind) and
         is_integer(index) and index >= 0 and index > previous_index and
         is_binary(Map.get(record, :item_id)) do
      {:ok, index}
    else
      :error
    end
  end

  defp validate_direct_record(_record, _kind, _previous_index), do: :error

  defp valid_direct_record_keys?(record, :result),
    do: MapSet.new(Map.keys(record)) == MapSet.new([:item_id, :index, :output])

  defp valid_direct_record_keys?(record, :error),
    do: MapSet.new(Map.keys(record)) == MapSet.new([:item_id, :index, :error])

  defp valid_direct_record_value?(record, :result),
    do: valid_reduce_accumulator?(Map.get(record, :output))

  defp valid_direct_record_value?(record, :error),
    do: is_exception(Map.get(record, :error))

  defp validate_direct_record_identity(results, errors) do
    records = results ++ errors
    indexes = Enum.map(records, & &1.index)
    item_ids = Enum.map(records, & &1.item_id)

    if length(Enum.uniq(indexes)) == length(indexes) and
         length(Enum.uniq(item_ids)) == length(item_ids) do
      :ok
    else
      {:error, []}
    end
  end

  defp invalid_direct_map_result(reduce, path) do
    {:error,
     Error.execution_error("reduce received an invalid Map result", %{
       phase: :reduce_collection,
       node: reduce.name,
       reason: :invalid_map_result,
       retry: false,
       path: path
     })}
  end

  defp validate_reduce_initial(reduce, initial) do
    if valid_reduce_accumulator?(initial) do
      {:ok, initial}
    else
      {:error,
       Error.execution_error("reduce initial value must be a map or Jido.Action.Output", %{
         phase: :reduce_initial,
         node: reduce.name,
         reason: :output_envelope_required,
         value_type: value_type(initial),
         retry: false
       })}
    end
  end

  defp valid_reduce_accumulator?(%Output{} = output),
    do: match?({:ok, _}, Output.validate(output))

  defp valid_reduce_accumulator?(value), do: is_map(value)

  defp fold_reduce_items(reduce, items, initial, state) do
    items
    |> Enum.reduce_while({:ok, initial, 0}, fn item_state, {:ok, accumulator, completed} ->
      case run_reduce_item(reduce, item_state, accumulator, state) do
        {:ok, next_accumulator} -> {:cont, {:ok, next_accumulator, completed + 1}}
        {:error, error} -> {:halt, {:error, error, completed + 1, completed}}
      end
    end)
    |> case do
      {:ok, accumulator, completed_count} ->
        {:ok, accumulator, reduce_metadata(reduce, length(items), completed_count)}

      {:error, error, item_count, completed_count} ->
        {:error, error, state, reduce_metadata(reduce, item_count, completed_count)}
    end
  end

  defp run_reduce_item(reduce, item_state, accumulator, state) do
    metadata = collection_item_metadata(:reduce, reduce, item_state, state)

    :telemetry.span([:jido, :flow, :reduce, :item], metadata, fn ->
      local_state =
        state
        |> Map.merge(item_state)
        |> Map.put(:accumulator, accumulator)

      result =
        with {:ok, params} <- resolve_reduce_input(reduce, local_state, item_state) do
          run_resolved_target(
            reduce.action,
            params,
            state.context,
            reduce_target_owner(reduce, item_state)
          )
        end

      {result, Map.merge(metadata, reduce_item_result_metadata(result))}
    end)
  end

  defp resolve_reduce_input(reduce, state, item_state) do
    reduce.input
    |> resolve_expr(state)
    |> tag_target_validation_error(:input, reduce_target_owner(reduce, item_state))
  end

  defp dispatch_map_items(%FlowMap{on_error: :fail_fast} = map, items, state) do
    window_size = map_window_size(state.options)

    items
    |> Stream.chunk_every(window_size)
    |> Enum.reduce_while({:ok, [], 0, 0}, fn window,
                                             {:ok, result_chunks, success_before, started_before} ->
      outcomes = dispatch_map_window(map, window, state)
      successes = for {:ok, result} <- outcomes, do: result
      failures = for {:error, failure} <- outcomes, do: failure
      started_count = started_before + length(window)

      case failures do
        [] ->
          {:cont,
           {:ok, [successes | result_chunks], success_before + length(successes), started_count}}

        failures ->
          selected = Enum.min_by(failures, & &1.index)

          {:halt,
           {:error, selected.error, started_count, success_before + length(successes),
            length(failures)}}
      end
    end)
    |> case do
      {:ok, result_chunks, _success_count, _started_count} ->
        {:ok, result_chunks |> Enum.reverse() |> List.flatten(), []}

      {:error, error, started_count, success_count, error_count} ->
        {:error, error, started_count, success_count, error_count}
    end
  end

  defp dispatch_map_items(%FlowMap{on_error: :collect_errors}, [], _state),
    do: {:ok, [], []}

  defp dispatch_map_items(%FlowMap{on_error: :collect_errors} = map, items, state) do
    outcomes = dispatch_map_window(map, items, state)

    results = for {:ok, result} <- outcomes, do: result
    errors = for {:error, error} <- outcomes, do: error
    {:ok, results, errors}
  end

  defp dispatch_map_window(map, items, state) do
    if Keyword.fetch!(state.options, :async) do
      execute_async_map_items(map, items, state)
    else
      Enum.map(items, &run_map_item(map, &1, state))
    end
  end

  defp execute_async_map_items(map, items, state) do
    caller = self()
    reference = make_ref()

    {helper, monitor} =
      spawn_monitor(fn ->
        helper = self()
        span_owner = {helper, reference}
        spawn(fn -> terminate_map_helper_with_caller(caller, helper) end)
        Process.flag(:trap_exit, true)

        outcomes =
          items
          |> Task.async_stream(&run_map_item(map, &1, state, span_owner),
            max_concurrency: Keyword.fetch!(state.options, :max_concurrency),
            timeout: :infinity,
            ordered: true
          )
          |> Stream.zip(items)
          |> Enum.map(fn
            {{:ok, outcome}, item_state} ->
              take_map_item_span(reference, item_state.item_id)
              outcome

            {{:exit, reason}, item_state} ->
              span = take_map_item_span(reference, item_state.item_id)
              map_item_task_exit(map, item_state, state, reason, span)
          end)

        send(caller, {reference, self(), outcomes})
      end)

    receive do
      {^reference, ^helper, outcomes} ->
        Process.demonitor(monitor, [:flush])
        outcomes

      {:DOWN, ^monitor, :process, ^helper, reason} ->
        exit(reason)
    end
  end

  defp terminate_map_helper_with_caller(caller, helper) do
    caller_monitor = Process.monitor(caller)
    helper_monitor = Process.monitor(helper)

    receive do
      {:DOWN, ^caller_monitor, :process, ^caller, _reason} -> Process.exit(helper, :kill)
      {:DOWN, ^helper_monitor, :process, ^helper, _reason} -> :ok
    end
  end

  defp run_map_item(map, item_state, state) do
    run_map_item(map, item_state, state, nil)
  end

  defp run_map_item(map, item_state, state, span_owner) do
    metadata = collection_item_metadata(:map, map, item_state, state)

    map_item_span(metadata, span_owner, item_state.item_id, fn ->
      local_state = Map.merge(state, item_state)

      result =
        with {:ok, params} <- resolve_map_input(map, local_state, item_state),
             {:ok, output} <-
               run_resolved_target(
                 map.action,
                 params,
                 state.context,
                 map_target_owner(map, item_state)
               ) do
          {:ok, %{item_id: item_state.item_id, index: item_state.item_index, output: output}}
        else
          {:error, error} ->
            {:error, %{item_id: item_state.item_id, index: item_state.item_index, error: error}}
        end

      {result, Map.merge(metadata, map_item_result_metadata(result))}
    end)
  end

  defp resolve_map_input(map, state, item_state) do
    map.input
    |> resolve_expr(state)
    |> tag_target_validation_error(:input, map_target_owner(map, item_state))
  end

  defp map_item_span(metadata, span_owner, item_id, fun) do
    start_time = System.monotonic_time()
    span_context = make_ref()
    span_metadata = Map.put_new(metadata, :telemetry_span_context, span_context)

    :telemetry.execute(
      [:jido, :flow, :map, :item, :start],
      %{monotonic_time: start_time, system_time: System.system_time()},
      span_metadata
    )

    notify_map_item_span_owner(span_owner, item_id, start_time, span_context)

    try do
      {result, stop_metadata} = fun.()
      stop_time = System.monotonic_time()

      :telemetry.execute(
        [:jido, :flow, :map, :item, :stop],
        %{duration: stop_time - start_time, monotonic_time: stop_time},
        Map.put_new(stop_metadata, :telemetry_span_context, span_context)
      )

      result
    catch
      kind, reason ->
        stop_time = System.monotonic_time()

        :telemetry.execute(
          [:jido, :flow, :map, :item, :exception],
          %{duration: stop_time - start_time, monotonic_time: stop_time},
          Map.merge(span_metadata, %{
            kind: kind,
            reason: reason,
            stacktrace: __STACKTRACE__
          })
        )

        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  defp notify_map_item_span_owner(nil, _item_id, _start_time, _span_context), do: :ok

  defp notify_map_item_span_owner({owner, reference}, item_id, start_time, span_context) do
    send(owner, {:map_item_span_started, reference, item_id, start_time, span_context})
  end

  defp take_map_item_span(reference, item_id) do
    receive do
      {:map_item_span_started, ^reference, ^item_id, start_time, span_context} ->
        {start_time, span_context}
    end
  end

  defp map_item_task_exit(map, item_state, state, reason, span) do
    error =
      Error.execution_error("flow map item task exited", %{
        phase: :map_target_execution,
        node: map.name,
        target: map.action,
        item_index: item_state.item_index,
        item_id: item_state.item_id,
        reason: reason
      })

    metadata =
      :map
      |> collection_item_metadata(map, item_state, state)
      |> Map.merge(%{status: :error, error_type: error_type(error)})

    {measurements, metadata} = map_item_exit_telemetry(metadata, span)

    :telemetry.execute(
      [:jido, :flow, :map, :item, :stop],
      measurements,
      metadata
    )

    {:error, %{item_id: item_state.item_id, index: item_state.item_index, error: error}}
  end

  defp map_item_exit_telemetry(metadata, {start_time, span_context}) do
    stop_time = System.monotonic_time()

    {
      %{duration: stop_time - start_time, monotonic_time: stop_time},
      Map.put(metadata, :telemetry_span_context, span_context)
    }
  end

  defp map_window_size(options) do
    if Keyword.fetch!(options, :async) do
      Keyword.fetch!(options, :max_concurrency)
    else
      1
    end
  end

  defp normalize_runtime_options(options) do
    [
      async: Keyword.get(options, :async, false),
      max_concurrency: Keyword.get(options, :max_concurrency, System.schedulers_online())
    ]
  end

  defp collection_element?(%FlowMap{}), do: true
  defp collection_element?(%Reduce{}), do: true
  defp collection_element?(_element), do: false

  defp flow_module?(action) do
    function_exported?(action, :__jido_flow__, 0)
  end

  defp select_choice_target(%Choice{} = choice, state) do
    choice.options
    |> Enum.reduce_while({:ok, choice.fallback}, fn option, {:ok, _fallback} ->
      case evaluate_condition(option.condition, state, choice.name, option.name) do
        {:ok, true} -> {:halt, {:ok, option}}
        {:ok, false} -> {:cont, {:ok, choice.fallback}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp evaluate_condition(%Condition{operator: :all, operands: conditions}, state, node, option) do
    Enum.reduce_while(conditions, {:ok, true}, fn condition, {:ok, true} ->
      case evaluate_condition(condition, state, node, option) do
        {:ok, true} -> {:cont, {:ok, true}}
        {:ok, false} -> {:halt, {:ok, false}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp evaluate_condition(%Condition{operator: :any, operands: conditions}, state, node, option) do
    Enum.reduce_while(conditions, {:ok, false}, fn condition, {:ok, false} ->
      case evaluate_condition(condition, state, node, option) do
        {:ok, true} -> {:halt, {:ok, true}}
        {:ok, false} -> {:cont, {:ok, false}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp evaluate_condition(%Condition{operator: :not, operands: [condition]}, state, node, option) do
    case evaluate_condition(condition, state, node, option) do
      {:ok, result} -> {:ok, not result}
      {:error, error} -> {:error, error}
    end
  end

  defp evaluate_condition(
         %Condition{operator: operator, operands: [left, right]},
         state,
         node,
         option
       ) do
    with {:ok, left} <- resolve_expr(left, state),
         {:ok, right} <- resolve_expr(right, state) do
      evaluate_comparison(operator, left, right, node, option)
    end
  end

  defp evaluate_comparison(:eq, left, right, _node, _option), do: {:ok, left == right}
  defp evaluate_comparison(:neq, left, right, _node, _option), do: {:ok, left != right}

  defp evaluate_comparison(operator, left, right, node, option)
       when operator in [:lt, :lte, :gt, :gte] do
    if comparable_choice_values?(left, right) do
      result =
        case operator do
          :lt -> left < right
          :lte -> left <= right
          :gt -> left > right
          :gte -> left >= right
        end

      {:ok, result}
    else
      invalid_choice_condition(operator, :invalid_ordering_operands, left, right, node, option)
    end
  end

  defp evaluate_comparison(:in, left, right, node, option) do
    case proper_list_member(right, left, false) do
      {:ok, member?} ->
        {:ok, member?}

      :error ->
        invalid_choice_condition(
          :in,
          :invalid_membership_right_operand,
          left,
          right,
          node,
          option
        )
    end
  end

  defp comparable_choice_values?(left, right) do
    (is_number(left) and is_number(right)) or (is_binary(left) and is_binary(right))
  end

  defp proper_list_member([], _value, member?), do: {:ok, member?}

  defp proper_list_member([head | tail], value, false),
    do: proper_list_member(tail, value, head == value)

  defp proper_list_member([_head | tail], value, true),
    do: proper_list_member(tail, value, true)

  defp proper_list_member(_value, _member, _member?), do: :error

  defp invalid_choice_condition(operator, reason, left, right, node, option) do
    {:error,
     Error.execution_error("invalid choice condition operands", %{
       phase: :choice_condition,
       node: node,
       option: option,
       operator: operator,
       reason: reason,
       left_type: choice_value_type(left),
       right_type: choice_value_type(right),
       retry: false
     })}
  end

  defp choice_value_type(value) when is_number(value), do: :number
  defp choice_value_type(value) when is_binary(value), do: :binary
  defp choice_value_type(value) when is_list(value), do: :list
  defp choice_value_type(value) when is_map(value), do: :map
  defp choice_value_type(value) when is_atom(value), do: :atom
  defp choice_value_type(value) when is_tuple(value), do: :tuple
  defp choice_value_type(_value), do: :other

  defp run_resolved_target(action, params, context, owner) do
    if flow_module?(action) do
      action
      |> apply(:flow, [])
      |> Exec.run(params, context)
      |> tag_target_error(:execution, owner)
    else
      with {:ok, params} <- validate_target_input(action, params, owner),
           {:ok, output} <- call_target_action(action, params, context, owner),
           {:ok, output} <- validate_target_output(action, output, owner) do
        {:ok, output}
      end
    end
  end

  defp validate_target_input(action, params, owner) do
    Exec.validate_action_params(action, params)
    |> tag_target_validation_error(:input, owner)
  end

  defp call_target_action(action, params, context, owner) do
    action
    |> Exec.invoke_action(params, context)
    |> drop_action_extras()
    |> tag_target_error(:execution, owner)
  end

  defp validate_target_output(action, output, owner) do
    Exec.validate_action_output(action, output)
    |> tag_target_error(:output, owner)
  end

  defp node_target_owner(node), do: %{kind: :node, node: node}

  defp choice_target_owner(choice, target), do: %{kind: :choice, choice: choice, target: target}

  defp map_target_owner(map, item_state), do: %{kind: :map, map: map, item: item_state}

  defp reduce_target_owner(reduce, item_state),
    do: %{kind: :reduce, reduce: reduce, item: item_state}

  defp tag_target_error(result, phase, %{kind: :node, node: node}) do
    tag_step_error(result, node_target_phase(phase), node)
  end

  defp tag_target_error(result, phase, %{kind: :choice, choice: choice, target: target}) do
    tag_choice_target_error(result, choice, target, choice_target_phase(phase))
  end

  defp tag_target_error(result, phase, %{kind: :map, map: map, item: item}) do
    tag_map_target_error(result, map, item, map_target_phase(phase))
  end

  defp tag_target_error(result, phase, %{kind: :reduce, reduce: reduce, item: item}) do
    tag_reduce_target_error(result, reduce, item, reduce_target_phase(phase))
  end

  defp tag_target_validation_error(result, :input, %{kind: :node, node: node}) do
    tag_step_validation_error(result, :step_input, node)
  end

  defp tag_target_validation_error(result, :input, %{
         kind: :choice,
         choice: choice,
         target: target
       }) do
    tag_choice_target_validation_error(result, choice, target, :choice_target_input)
  end

  defp tag_target_validation_error(result, :input, %{kind: :map, map: map, item: item}) do
    tag_map_target_validation_error(result, map, item, :map_target_input)
  end

  defp tag_target_validation_error(result, :input, %{
         kind: :reduce,
         reduce: reduce,
         item: item
       }) do
    tag_reduce_target_validation_error(result, reduce, item, :reduce_target_input)
  end

  defp node_target_phase(:execution), do: :step_execution
  defp node_target_phase(:output), do: :step_output

  defp choice_target_phase(:execution), do: :choice_target_execution
  defp choice_target_phase(:output), do: :choice_target_output

  defp map_target_phase(:execution), do: :map_target_execution
  defp map_target_phase(:output), do: :map_target_output

  defp reduce_target_phase(:execution), do: :reduce_target_execution
  defp reduce_target_phase(:output), do: :reduce_target_output

  defp node_metadata(%Choice{} = choice, node_state) do
    %{flow: node_state.flow, node: choice.name, kind: :choice}
  end

  defp node_metadata(%FlowMap{} = map, node_state) do
    %{flow: node_state.flow, node: map.name, kind: :map}
  end

  defp node_metadata(%Reduce{} = reduce, node_state) do
    %{flow: node_state.flow, node: reduce.name, kind: :reduce}
  end

  defp node_metadata(node, node_state) do
    %{flow: node_state.flow, node: node.name, action: node.action}
  end

  defp node_result_metadata({:error, error, _state}) do
    %{status: :error, error_type: error_type(error)}
  end

  defp node_result_metadata({:error, error, _state, choice_metadata}) do
    Map.merge(%{status: :error, error_type: error_type(error)}, choice_metadata)
  end

  defp node_result_metadata({:ok, _output, choice_metadata}) do
    Map.merge(%{status: :ok}, choice_metadata)
  end

  defp node_result_metadata(_result), do: %{status: :ok}

  defp error_type(error), do: error |> Error.to_map() |> Map.get(:type)

  defp map_metadata(map, item_count, success_count, error_count) do
    %{
      target: map.action,
      on_error: map.on_error,
      item_count: item_count,
      success_count: success_count,
      error_count: error_count
    }
  end

  defp map_item_result_metadata({:ok, _result}), do: %{status: :ok}

  defp map_item_result_metadata({:error, %{error: error}}) do
    %{status: :error, error_type: error_type(error)}
  end

  defp reduce_metadata(reduce, item_count, completed_count) do
    %{
      target: reduce.action,
      item_count: item_count,
      completed_count: completed_count
    }
  end

  defp collection_item_metadata(kind, element, item_state, state) do
    %{
      flow: state.flow,
      node: element.name,
      kind: kind,
      target: element.action,
      item_id: item_state.item_id,
      item_index: item_state.item_index
    }
  end

  defp reduce_item_result_metadata({:ok, _result}), do: %{status: :ok}

  defp reduce_item_result_metadata({:error, error}) do
    %{status: :error, error_type: error_type(error)}
  end

  defp dependency_results(%{deps: []}, _parent_value), do: %{}
  defp dependency_results(%{deps: [dep]}, parent_value), do: %{dep => parent_value}

  defp dependency_results(%{deps: deps}, parent_values) when is_list(parent_values) do
    # Multi-parent nodes are attached with `to: deps`; Runic joins preserve that same order.
    deps
    |> Enum.zip(parent_values)
    |> Map.new()
  end

  defp raise_node_error(node, error, state) do
    record_node_error(node, error, state)
    raise NodeError, node: node.name, error: error
  end

  defp record_node_error(node, error, %{@collector_key => {runner, run_ref}})
       when is_pid(runner) do
    send(runner, {run_ref, :node_error, node.name, error})
  end

  defp record_node_error(_node, _error, _state), do: :ok

  defp drain_node_errors(run_ref, ordered_nodes) do
    node_index =
      ordered_nodes
      |> Enum.with_index()
      |> Map.new(fn {node, index} -> {node.name, index} end)

    run_ref
    |> do_drain_node_errors([])
    |> Enum.sort_by(fn {node, _error} -> Map.fetch!(node_index, node) end)
  end

  defp do_drain_node_errors(run_ref, acc) do
    receive do
      {^run_ref, :node_error, node, error} ->
        do_drain_node_errors(run_ref, [{node, error} | acc])
    after
      0 ->
        acc
    end
  end

  # Extras are instruction-path-only; flow nodes deliberately discard them.
  defp drop_action_extras({:ok, output, _extras}), do: {:ok, output}
  defp drop_action_extras({:error, error}), do: {:error, error}

  defp tag_step_error({:ok, output}, _phase, _node), do: {:ok, output}

  defp tag_step_error({:error, error}, phase, node) when is_exception(error) do
    {:error, put_step_details(error, phase, node)}
  end

  defp tag_step_error({:error, error}, _phase, _node), do: {:error, error}

  defp put_step_details(%{details: details} = error, phase, node) when is_map(details) do
    %{
      error
      | details: Map.merge(details, %{phase: phase, node: node.name, action: node.action})
    }
  end

  defp put_step_details(error, _phase, _node), do: error

  defp tag_choice_target_error({:ok, output}, _choice, _target, _phase), do: {:ok, output}

  defp tag_choice_target_error({:error, error}, choice, target, phase) when is_exception(error) do
    {:error, put_choice_target_details(error, choice, target, phase)}
  end

  defp tag_choice_target_error({:error, error}, _choice, _target, _phase), do: {:error, error}

  defp tag_choice_target_validation_error({:ok, value}, _choice, _target, _phase),
    do: {:ok, value}

  defp tag_choice_target_validation_error({:error, error}, choice, target, phase)
       when is_exception(error) do
    {:error, put_choice_target_details(error, choice, target, phase)}
  end

  defp tag_choice_target_validation_error({:error, reason}, choice, target, phase) do
    {:error,
     Error.validation_error(
       to_error_message(reason),
       choice_target_details(%{reason: reason}, choice, target, phase)
     )}
  end

  defp tag_map_target_error({:ok, output}, _map, _item, _phase), do: {:ok, output}

  defp tag_map_target_error({:error, error}, map, item, phase) when is_exception(error) do
    {:error, put_map_target_details(error, map, item, phase)}
  end

  defp tag_map_target_error({:error, error}, _map, _item, _phase), do: {:error, error}

  defp tag_map_target_validation_error({:ok, value}, _map, _item, _phase), do: {:ok, value}

  defp tag_map_target_validation_error({:error, error}, map, item, phase)
       when is_exception(error) do
    {:error, put_map_target_details(error, map, item, phase)}
  end

  defp tag_map_target_validation_error({:error, reason}, map, item, phase) do
    {:error,
     Error.validation_error(
       to_error_message(reason),
       map_target_details(%{reason: reason}, map, item, phase)
     )}
  end

  defp tag_reduce_target_error({:ok, output}, _reduce, _item, _phase), do: {:ok, output}

  defp tag_reduce_target_error({:error, error}, reduce, item, phase)
       when is_exception(error) do
    {:error, put_reduce_target_details(error, reduce, item, phase)}
  end

  defp tag_reduce_target_error({:error, error}, _reduce, _item, _phase),
    do: {:error, error}

  defp tag_reduce_target_validation_error({:ok, value}, _reduce, _item, _phase),
    do: {:ok, value}

  defp tag_reduce_target_validation_error({:error, error}, reduce, item, phase)
       when is_exception(error) do
    {:error, put_reduce_target_details(error, reduce, item, phase)}
  end

  defp tag_reduce_target_validation_error({:error, reason}, reduce, item, phase) do
    {:error,
     Error.validation_error(
       to_error_message(reason),
       reduce_target_details(%{reason: reason}, reduce, item, phase)
     )}
  end

  defp put_map_target_details(%{details: details} = error, map, item, phase)
       when is_map(details) do
    %{error | details: map_target_details(details, map, item, phase)}
  end

  defp put_map_target_details(error, _map, _item, _phase), do: error

  defp map_target_details(details, map, item, phase) do
    Map.merge(details, %{
      phase: phase,
      node: map.name,
      target: map.action,
      item_index: item.item_index,
      item_id: item.item_id
    })
  end

  defp put_reduce_target_details(%{details: details} = error, reduce, item, phase)
       when is_map(details) do
    %{error | details: reduce_target_details(details, reduce, item, phase)}
  end

  defp put_reduce_target_details(error, _reduce, _item, _phase), do: error

  defp reduce_target_details(details, reduce, item, phase) do
    Map.merge(details, %{
      phase: phase,
      node: reduce.name,
      target: reduce.action,
      item_index: item.item_index,
      item_id: item.item_id
    })
  end

  defp put_choice_target_details(%{details: details} = error, choice, target, phase)
       when is_map(details) do
    %{error | details: choice_target_details(details, choice, target, phase)}
  end

  defp put_choice_target_details(error, _choice, _target, _phase), do: error

  defp choice_target_details(details, choice, target, phase) do
    Map.merge(details, %{
      phase: phase,
      node: choice.name,
      option: target.name,
      target: target.action
    })
  end

  defp tag_step_validation_error({:ok, value}, _phase, _node), do: {:ok, value}

  defp tag_step_validation_error({:error, error}, phase, node) when is_exception(error) do
    details =
      error
      |> Map.get(:details, %{})
      |> Map.put(:phase, phase)
      |> Map.put(:node, node.name)
      |> Map.put(:action, node.action)

    {:error, Error.validation_error(Exception.message(error), details)}
  end

  defp tag_step_validation_error({:error, reason}, phase, node) do
    {:error,
     Error.validation_error(to_error_message(reason), %{
       phase: phase,
       node: node.name,
       action: node.action,
       reason: reason
     })}
  end

  defp resolve_expr(%Ref{type: :input, path: path}, state),
    do: {:ok, fetch_path(state.input, path)}

  defp resolve_expr(%Ref{type: :context, path: path}, state),
    do: {:ok, fetch_path(state.context, path)}

  defp resolve_expr(%Ref{type: :value, value: value}, _state), do: {:ok, value}

  defp resolve_expr(%Ref{type: :result, node: node, path: path}, state) do
    {:ok, state.results |> Map.get(node) |> fetch_path(path)}
  end

  defp resolve_expr(%Ref{type: :item, path: path}, state),
    do: {:ok, state |> Map.get(:item) |> fetch_path(path)}

  defp resolve_expr(%Ref{type: :item_index}, state), do: {:ok, Map.get(state, :item_index)}
  defp resolve_expr(%Ref{type: :item_id}, state), do: {:ok, Map.get(state, :item_id)}

  defp resolve_expr(%Ref{type: :accumulator, path: path}, state),
    do: {:ok, state |> Map.get(:accumulator) |> fetch_path(path)}

  defp resolve_expr(%Ref{type: type}, _state) do
    {:error, Error.validation_error("unsupported flow ref type: #{inspect(type)}", %{type: type})}
  end

  defp resolve_expr(%{} = map, state) do
    Enum.reduce_while(map, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      case resolve_expr(value, state) do
        {:ok, resolved} -> {:cont, {:ok, Map.put(acc, key, resolved)}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp resolve_expr(list, state) when is_list(list) do
    Enum.reduce_while(list, {:ok, []}, fn value, {:ok, acc} ->
      case resolve_expr(value, state) do
        {:ok, resolved} -> {:cont, {:ok, [resolved | acc]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      {:error, error} -> {:error, error}
    end
  end

  defp resolve_expr(value, _state), do: {:ok, value}

  defp extract_return(return_expr, workflow, input, context) do
    result_nodes = return_expr |> Node.collect_result_refs() |> Enum.uniq()
    facts_by_node = Workflow.results(workflow, result_nodes, facts: true, all: true)

    result_nodes
    |> Enum.reduce_while({:ok, %{}}, fn node, {:ok, acc} ->
      case Map.get(facts_by_node, node, []) do
        [] ->
          {:halt, {:error, Error.execution_error("flow execution produced no final state")}}

        facts ->
          value = facts |> List.last() |> Map.fetch!(:value)
          {:cont, {:ok, Map.put(acc, node, value)}}
      end
    end)
    |> case do
      {:ok, results} ->
        resolve_expr(return_expr, %{input: input, context: context, results: results})

      {:error, error} ->
        {:error, error}
    end
  end

  defp fetch_path(value, []), do: value
  defp fetch_path(nil, _path), do: nil

  defp fetch_path(value, [key | rest]) when is_map(value) do
    value
    |> fetch_key(key)
    |> fetch_path(rest)
  end

  defp fetch_path(value, [key | rest]) when is_list(value) and is_integer(key) and key >= 0 do
    value
    |> Enum.at(key)
    |> fetch_path(rest)
  end

  defp fetch_path(_value, _path), do: nil

  defp fetch_key(map, key) do
    cond do
      Map.has_key?(map, key) ->
        Map.get(map, key)

      is_atom(key) and Map.has_key?(map, Atom.to_string(key)) ->
        Map.get(map, Atom.to_string(key))

      true ->
        nil
    end
  end

  defp value_type(nil), do: nil
  defp value_type(%Output{}), do: :action_output
  defp value_type(value) when is_list(value), do: :list
  defp value_type(value) when is_map(value), do: :map
  defp value_type(value) when is_binary(value), do: :binary
  defp value_type(value) when is_number(value), do: :number
  defp value_type(value) when is_atom(value), do: :atom
  defp value_type(value) when is_tuple(value), do: :tuple
  defp value_type(_value), do: :other

  defp to_error_message(message) when is_binary(message), do: message
  defp to_error_message(message) when is_atom(message), do: Atom.to_string(message)
  defp to_error_message(message), do: inspect(message)
end
