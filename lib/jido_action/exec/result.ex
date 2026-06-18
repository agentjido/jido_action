defmodule Jido.Exec.Result do
  @moduledoc """
  Result value returned by Runic-backed Jido execution.

  The result keeps the underlying `Runic.Workflow` available for advanced use
  while presenting a small Jido-facing shape for status, results, events, cycle
  count, and errors.
  """

  alias Jido.Action.Error
  alias Runic.Workflow
  alias Runic.Workflow.Runnable

  @schema Zoi.struct(
            __MODULE__,
            %{
              workflow: Zoi.struct(Workflow, description: "Underlying Runic workflow"),
              status:
                Zoi.enum([:ok, :error, :max_cycles],
                  description: "Final Runic execution status"
                ),
              results:
                Zoi.any(description: "Grouped workflow results")
                |> Zoi.optional()
                |> Zoi.default(nil),
              events:
                Zoi.list(Zoi.any(), description: "Runtime events")
                |> Zoi.optional()
                |> Zoi.default([]),
              cycles:
                Zoi.integer(gte: 0, description: "Number of dispatch cycles")
                |> Zoi.optional()
                |> Zoi.default(0),
              error:
                Zoi.any(description: "Normalized runtime error")
                |> Zoi.optional()
                |> Zoi.default(nil),
              directives:
                Zoi.list(Zoi.map(), description: "Action directives captured from flow steps")
                |> Zoi.optional()
                |> Zoi.default([])
            },
            coerce: true
          )

  @type status :: :ok | :error | :max_cycles
  @type t :: unquote(Zoi.type_spec(@schema))

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc false
  @spec new(Workflow.t(), status(), keyword()) :: t()
  def new(%Workflow{} = workflow, status, opts \\ []) when is_list(opts) do
    %{
      workflow: workflow,
      status: status,
      results: Keyword.get_lazy(opts, :results, fn -> workflow_results(workflow) end),
      events: Keyword.get_lazy(opts, :events, fn -> workflow_events(workflow) end),
      cycles: Keyword.get(opts, :cycles, 0),
      error: Keyword.get(opts, :error),
      directives: Keyword.get_lazy(opts, :directives, fn -> workflow_directives(workflow) end)
    }
    |> parse_result!()
  end

  @doc false
  @spec failed(Workflow.t(), Runnable.t(), keyword()) :: {:error, t()}
  def failed(%Workflow{} = workflow, %Runnable{} = runnable, opts \\ []) when is_list(opts) do
    directives =
      workflow
      |> workflow_directives()
      |> Kernel.++(failed_runnable_directives(runnable))

    {:error,
     new(workflow, :error,
       cycles: Keyword.get(opts, :cycles, 0),
       error: failed_runnable_error(runnable),
       events: Keyword.get_lazy(opts, :events, fn -> workflow_events(workflow) end),
       directives: directives
     )}
  end

  @doc false
  @spec max_cycles(Workflow.t(), pos_integer(), keyword()) :: {:error, t()}
  def max_cycles(%Workflow{} = workflow, max_cycles, opts \\ []) when is_integer(max_cycles) do
    cycles = Keyword.get(opts, :cycles, 0)

    error =
      Error.execution_error("flow exceeded max dispatch cycles", %{
        max_cycles: max_cycles,
        cycles: cycles
      })

    {:error,
     new(workflow, :max_cycles,
       cycles: cycles,
       error: error,
       events: Keyword.get_lazy(opts, :events, fn -> workflow_events(workflow) end)
     )}
  end

  @doc false
  @spec workflow_results(Workflow.t(), keyword()) :: term()
  def workflow_results(%Workflow{} = workflow, opts \\ []) when is_list(opts) do
    if Keyword.get(opts, :raw, false) do
      Workflow.raw_productions(workflow)
    else
      opts = Keyword.drop(opts, [:raw])
      components = Keyword.get(opts, :components)
      query_opts = Keyword.delete(opts, :components)

      results =
        if is_list(components) do
          Workflow.results(workflow, components, query_opts)
        else
          Workflow.results(workflow, nil, query_opts)
        end

      filter_internal_results(workflow, results)
    end
  end

  defp parse_result!(attrs) do
    case Zoi.parse(@schema, attrs) do
      {:ok, result} ->
        result

      {:error, errors} ->
        raise ArgumentError, "invalid execution result:\n" <> Zoi.prettify_errors(errors)
    end
  end

  defp workflow_events(%Workflow{} = workflow) do
    Workflow.event_log(workflow)
  end

  defp filter_internal_results(%Workflow{} = workflow, results) when is_map(results) do
    visible_names = visible_component_names(workflow)

    Map.filter(results, fn {name, _value} ->
      MapSet.member?(visible_names, name)
    end)
  end

  defp visible_component_names(%Workflow{} = workflow) do
    workflow
    |> Workflow.components()
    |> Enum.reject(&internal_component?/1)
    |> Enum.map(fn {name, _component} -> name end)
    |> MapSet.new()
  end

  defp internal_component?({_name, %Runic.Workflow.Step{name: "step_" <> _suffix}}), do: true
  defp internal_component?(_component), do: false

  defp failed_runnable_error(%Runnable{} = runnable) do
    Error.execution_error("flow runnable failed", %{
      runnable_id: runnable.id,
      node: runnable_node_name(runnable),
      reason: runnable.error
    })
  end

  defp runnable_node_name(%Runnable{node: %{name: name}}) when not is_nil(name), do: name
  defp runnable_node_name(%Runnable{node: %{hash: hash}}) when not is_nil(hash), do: hash
  defp runnable_node_name(%Runnable{node: node}), do: inspect(node)

  defp workflow_directives(%Workflow{} = workflow) do
    workflow
    |> Workflow.facts()
    |> Enum.flat_map(&fact_directives/1)
  end

  defp fact_directives(%Runic.Workflow.Fact{hash: fact_hash, meta: meta})
       when is_map(meta) do
    with {:ok, directives} <- Map.fetch(meta, :jido_directives),
         {:ok, step} <- Map.fetch(meta, :jido_step),
         {:ok, status} <- Map.fetch(meta, :jido_status) do
      [
        %{
          step: step,
          status: status,
          fact_hash: fact_hash,
          directives: directives
        }
      ]
    else
      :error -> []
    end
  end

  defp fact_directives(_fact), do: []

  defp failed_runnable_directives(%Runnable{error: error, node: node}) do
    error
    |> error_directive_meta()
    |> case do
      nil ->
        []

      %{directives: directives} = meta ->
        [
          %{
            step: Map.get(meta, :step, runnable_node_name(%Runnable{node: node})),
            status: Map.get(meta, :status, :error),
            directives: directives
          }
        ]
    end
  end

  defp error_directive_meta(%Jido.Action.Error.ExecutionFailureError{details: details})
       when is_map(details) do
    case Map.get(details, :jido_directives) do
      nil ->
        nil

      directives ->
        %{
          directives: directives,
          step: Map.get(details, :jido_step),
          status: Map.get(details, :jido_status, :error)
        }
    end
  end

  defp error_directive_meta(_error), do: nil
end
