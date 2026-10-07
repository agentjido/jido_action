defmodule Jido.Exec.Flow.Validator do
  @moduledoc false

  alias Jido.Action.Output
  alias Jido.Flow
  alias Jido.Flow.Definition
  alias Jido.Flow.Error
  alias Jido.Flow.Graph
  alias Jido.Instruction

  @doc false
  @spec validate(Flow.t()) :: {:ok, Flow.t()} | {:error, Exception.t()}
  def validate(%Flow{} = flow) do
    with {:ok, flow, _subflows} <- prepare(flow) do
      {:ok, flow}
    end
  end

  @doc false
  @spec prepare(Flow.t(), [module()]) ::
          {:ok, Flow.t(), %{optional(module()) => Flow.t()}} | {:error, Exception.t()}
  def prepare(%Flow{} = flow, module_stack \\ []) when is_list(module_stack) do
    with {:ok, flow} <- Flow.validate(flow),
         {:ok, subflows} <- validate_component_targets(flow.components, module_stack, %{}) do
      {:ok, flow, subflows}
    end
  end

  @doc false
  @spec callback(module(), :validate_params | :validate_output, term()) ::
          {:ok, term()} | {:error, term()}
  def callback(module, callback, value) do
    case apply(module, callback, [value]) do
      {status, _value} = result when status in [:ok, :error] ->
        result

      result ->
        {:error,
         Error.invalid_execution_error("Flow validator returned an unsupported result", %{
           flow: module,
           callback: callback,
           result: result
         })}
    end
  rescue
    exception ->
      exception =
        if Map.has_key?(exception, :stacktrace) do
          Map.update!(exception, :stacktrace, &(&1 || __STACKTRACE__))
        else
          Map.put(exception, :stacktrace, %Splode.Stacktrace{stacktrace: __STACKTRACE__})
        end

      {:error, exception}
  catch
    kind, reason ->
      error =
        Error.invalid_execution_error("Flow validator #{kind}", %{
          flow: module,
          callback: callback,
          reason: reason
        })

      {:error, %{error | stacktrace: %Splode.Stacktrace{stacktrace: __STACKTRACE__}}}
  end

  @doc false
  @spec output_shape(module() | Jido.Flow.t(), term(), atom()) ::
          {:ok, term()} | {:error, Exception.t()}
  def output_shape(_flow, %Output{} = output, _callback), do: Output.validate(output)

  def output_shape(flow, output, callback) when is_map(output) do
    if is_struct(output) and Enumerable.impl_for(output) do
      {:error,
       Error.execution_error("Flow validator returned a value with an invalid shape", %{
         flow: flow,
         callback: callback,
         expected: :map_or_output_envelope,
         result: output
       })}
    else
      {:ok, output}
    end
  end

  def output_shape(flow, output, _callback) do
    {:error,
     Jido.Action.Error.validation_error("Action output validation must return a map", %{
       context: "Action output",
       subject: flow,
       value: output
     })}
  end

  defp validate_component_targets(components, module_stack, subflows) do
    components
    |> Graph.canonical_components()
    |> Enum.reduce_while({:ok, subflows}, fn {name, node}, {:ok, subflows} ->
      case validate_target(name, node, module_stack, subflows) do
        {:ok, subflows} -> {:cont, {:ok, subflows}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp validate_target(
         name,
         %{kind: :call, call: {%Instruction{kind: :flow} = template, _params}},
         module_stack,
         subflows
       ) do
    module = template.target

    with {:ok, _instruction} <- bind_template(template, :flow, name),
         :ok <- reject_recursive_subflow(module, module_stack),
         {:ok, subflows} <- materialize_subflow(module, module_stack, subflows) do
      {:ok, subflows}
    else
      {:error, error} -> {:error, target_error(error, name, :flow)}
    end
  end

  defp validate_target(name, node, _module_stack, subflows) do
    node
    |> Definition.calls()
    |> Enum.reduce_while({:ok, subflows}, fn {field, template, _params}, {:ok, subflows} ->
      field = validation_field(node, field)

      case bind_template(template, :action, name) do
        {:ok, _instruction} ->
          {:cont, {:ok, subflows}}

        {:error, error} ->
          {:halt, {:error, target_error(error, name, field)}}
      end
    end)
  end

  defp materialize_subflow(module, module_stack, subflows) do
    case Map.fetch(subflows, module) do
      {:ok, _flow} ->
        {:ok, subflows}

      :error ->
        with {:ok, child} <- load_child_flow(module),
             {:ok, child} <- Flow.validate(child),
             :ok <- reject_dispatch_subflow(child, module),
             {:ok, subflows} <-
               validate_component_targets(child.components, [module | module_stack], subflows) do
          {:ok, Map.put(subflows, module, child)}
        end
    end
  end

  defp reject_dispatch_subflow(%Flow{components: components}, module) do
    if Enum.any?(components, fn {_name, node} -> node.kind == :dispatch end) do
      {:error,
       Error.validation_error("a Flow with Dispatch cannot be used as a Subflow", %{flow: module})}
    else
      :ok
    end
  end

  defp reject_recursive_subflow(module, module_stack) do
    if module in module_stack do
      {:error,
       Error.validation_error("recursive Subflow module cycle", %{
         flow: module,
         module_stack: Enum.reverse([module | module_stack])
       })}
    else
      :ok
    end
  end

  defp load_child_flow(module) do
    case module.flow() do
      %Flow{} = flow ->
        {:ok, flow}

      value ->
        {:error,
         Error.validation_error("Subflow flow/0 must return a Jido.Flow", %{value: value})}
    end
  rescue
    error ->
      {:error, subflow_definition_error(%{error: error}, __STACKTRACE__)}
  catch
    kind, reason ->
      {:error, subflow_definition_error(%{kind: kind, reason: reason}, __STACKTRACE__)}
  end

  defp subflow_definition_error(details, frames) do
    error = Error.validation_error("Subflow flow/0 failed", details)
    %{error | stacktrace: %Splode.Stacktrace{stacktrace: frames}}
  end

  defp target_error(error, component, field) do
    details =
      error
      |> Map.get(:details, %{})
      |> Map.merge(%{component: component, field: field, cause: error.__struct__})

    tagged = Error.validation_error(Exception.message(error), details)

    case Map.get(error, :stacktrace) do
      nil -> tagged
      stacktrace -> %{tagged | stacktrace: stacktrace}
    end
  end

  defp bind_template(template, expected, component) do
    case Instruction.bind(template, %{}, %{}) do
      {:ok, %Instruction{kind: ^expected} = instruction} ->
        {:ok, instruction}

      {:error, %{details: %{actual: actual}}}
      when actual in [:action, :flow] ->
        {:error,
         Error.validation_error("Flow component has the wrong target kind", %{
           component: component,
           expected: expected,
           actual: actual
         })}

      {:error, error} ->
        {:error, error}
    end
  end

  defp validation_field(%{kind: kind}, _field) when kind in [:call, :map, :reduce, :iterate],
    do: :action

  defp validation_field(_node, field), do: field
end
