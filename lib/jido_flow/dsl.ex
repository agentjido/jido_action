defmodule Jido.Flow.DSL do
  @moduledoc """
  A macro-based DSL for defining Jido.Flow pipelines with support for sequential and parallel execution.

  ## Usage

      import Jido.Flow.DSL
      
      my_flow = flow "order_processing" do
        action ValidateOrder
        
        parallel do
          action CheckInventory
          action CheckCustomerCredit  
          action CalculateShipping
        end
        
        action ProcessPayment, when: &credit_approved?/1
        action SendConfirmation
      end

  ## Features

  - **Sequential Dependencies**: Actions are executed in order, with each depending on the previous
  - **Parallel Execution**: Use `parallel do...end` blocks to run actions concurrently  
  - **Conditional Execution**: Use `when` clauses to conditionally execute actions
  """

  alias Jido.Flow.Step

  @doc """
  Defines a flow using a DSL with support for sequential and parallel execution.
  """
  defmacro flow(name, do: block) do
    # Extract actions at compile time from the AST
    actions = extract_actions(block)
    
    quote do
      Jido.Flow.DSL.build_flow(unquote(name), unquote(Macro.escape(actions)))
    end
  end

  @doc """
  Defines an action step in a flow.
  """
  defmacro action(action_module) do
    quote do: {:action, unquote(action_module)}
  end

  @doc """
  Defines an action step with options in a flow.
  """
  defmacro action(action_module, opts) do
    quote do: {:action, unquote(action_module), unquote(opts)}
  end

  @doc """
  Defines a parallel execution block in a flow.
  """
  defmacro parallel(do: block) do
    parallel_actions = extract_actions(block)
    quote do: {:parallel, unquote(parallel_actions)}
  end

  # Extract actions from AST at compile time
  def extract_actions({:__block__, _, statements}) do
    Enum.map(statements, &extract_single_action/1)
  end

  def extract_actions(single_statement) do
    [extract_single_action(single_statement)]
  end

  defp extract_single_action({:action, _, [module]}) do
    {:action, resolve_module(module)}
  end

  defp extract_single_action({:action, _, [module, opts]}) do
    {:action, resolve_module(module), opts}
  end

  defp extract_single_action({:parallel, _, [[do: block]]}) do
    parallel_actions = extract_actions(block)
    {:parallel, parallel_actions}
  end

  defp extract_single_action(other) do
    {:unknown, other}
  end

  # Resolve module aliases to atoms
  defp resolve_module({:__aliases__, _, module_parts}) do
    Module.concat(module_parts)
  end

  defp resolve_module(module) when is_atom(module) do
    module
  end

  @doc """
  Builds a flow from a list of action specifications.
  """
  def build_flow(name, actions) when is_list(actions) do
    flow = Jido.Flow.new(name)
    
    {final_flow, _} = Enum.reduce(actions, {flow, nil}, fn action_spec, {acc_flow, last_step} ->
      process_action_spec(acc_flow, action_spec, last_step)
    end)
    
    final_flow
  end

  defp process_action_spec(flow, {:action, module}, last_step) do
    step = create_step(module)
    new_flow = add_step_to_flow(flow, step, last_step)
    {new_flow, step}
  end

  defp process_action_spec(flow, {:action, module, opts}, last_step) do
    step_metadata = case Keyword.get(opts, :when) do
      nil -> %{}
      condition -> %{condition: condition}
    end
    
    step = create_step(module, step_metadata)
    new_flow = add_step_to_flow(flow, step, last_step)
    {new_flow, step}
  end

  defp process_action_spec(flow, {:parallel, parallel_actions}, last_step) do
    # Create a parallel coordination step
    group_name = "parallel_group_#{System.unique_integer([:positive])}"
    group_step = Step.new(name: group_name, work: {__MODULE__, :identity, 1}, metadata: %{type: :parallel_group})
    
    # Add the group step
    flow_with_group = add_step_to_flow(flow, group_step, last_step)
    
    # Add all parallel actions as children of the group
    final_flow = Enum.reduce(parallel_actions, flow_with_group, fn action_spec, acc_flow ->
      {updated_flow, _} = process_action_spec(acc_flow, action_spec, group_step)
      updated_flow
    end)
    
    {final_flow, group_step}
  end

  defp process_action_spec(flow, {:unknown, _}, last_step) do
    {flow, last_step}
  end

  defp create_step(module, metadata \\ %{}) do
    step_name = module |> Module.split() |> List.last()
    Step.new(name: step_name, action: module, metadata: metadata)
  end

  defp add_step_to_flow(flow, step, nil) do
    Jido.Flow.add_step(flow, step)
  end

  defp add_step_to_flow(flow, step, parent_step) do
    Jido.Flow.add_step(flow, parent_step, step)
  end

  @doc """
  Identity function for parallel group coordination.
  """
  def identity(data), do: data
end
