defmodule Jido.Tools.FlowTool do
  @moduledoc """
  A behavior and macro for creating flow-based tools using the Jido Flow DSL.

  Provides a standardized way to create actions that execute predefined flows
  with sequential and parallel execution capabilities.
  """

  alias Jido.Action.Error
  alias Jido.Flow

  # Define the flow macro at the module level
  defmacro flow(name, do: block) do
    quote do
      # Build the flow using the DSL
      require Jido.Flow.DSL
      flow_def = Jido.Flow.DSL.flow(unquote(name), do: unquote(block))
      Module.put_attribute(__MODULE__, :jido_flows, flow_def)
      # Return the flow so it can be used immediately if needed
      flow_def
    end
  end

  @flow_config_schema NimbleOptions.new!(
                        name: [
                          type: :string,
                          required: true,
                          doc: "Name of the flow"
                        ],
                        timeout: [
                          type: :pos_integer,
                          default: 30_000,
                          doc: "Timeout for flow execution in milliseconds"
                        ]
                      )

  @doc """
  Callback for customizing flow execution or handling results.

  Takes the flow result and can transform or validate it.
  """
  @callback handle_result(any()) :: {:ok, any()} | {:error, any()}

  # Make handle_result optional
  @optional_callbacks [handle_result: 1]

  @doc """
  Macro for setting up a module as a FlowTool with flow execution capabilities.
  """
  defmacro __using__(opts) do
    escaped_schema = Macro.escape(@flow_config_schema)

    quote location: :keep do
      # Separate FlowTool-specific options from base Action options
      flow_keys = [:timeout]

      flow_opts =
        Keyword.take(unquote(opts), flow_keys) |> Keyword.put(:name, unquote(opts)[:name])

      action_opts = Keyword.drop(unquote(opts), flow_keys)

      # Validate FlowTool-specific options
      case NimbleOptions.validate(flow_opts, unquote(escaped_schema)) do
        {:ok, validated_flow_opts} ->
          # Store validated flow opts for later use
          @flow_opts validated_flow_opts

          # Pass the remaining options to the base Action
          use Jido.Action, action_opts

          # Implement the behavior
          @behaviour Jido.Tools.FlowTool

          # Store flows as they are defined
          Module.register_attribute(__MODULE__, :jido_flows, accumulate: true)

          # Register a before_compile hook to capture the flow
          @before_compile unquote(__MODULE__)

          # Automatically import necessary modules for FlowTool DSL
          require unquote(__MODULE__)
          import unquote(__MODULE__)
          require Jido.Flow.DSL
          import Jido.Flow.DSL, except: [flow: 2]
          
          # Make flow macro available without explicit import
          defmacro flow(name, opts \\ [], do: block) do
            quote do
              unquote(__MODULE__).flow(unquote(name), do: unquote(block))
            end
          end

          # Implement the run function that executes the flow
          @impl Jido.Action
          def run(params, context) do
            flow = get_flow()

            if flow do
              execute_flow(flow, params, context)
            else
              {:error, %{type: :flow_error, message: "No flow defined for #{__MODULE__}"}}
            end
          end

          # Helper function to execute the flow
          defp execute_flow(flow, params, context) do
            timeout = @flow_opts[:timeout]

            try do
              # Execute the flow with timeout using the Flow API
              task =
                Task.async(fn ->
                  run_flow_steps(flow, params, context)
                end)

result = Task.await(task, timeout)

# Call handle_result if implemented
handle_result(result)
            catch
              :exit, {:timeout, _} ->
                {:error,
                 %{type: :timeout_error, message: "Flow execution timed out after #{timeout}ms"}}

              error ->
                {:error,
                 %{type: :execution_error, message: "Flow execution failed: #{inspect(error)}"}}
            end
          end

          # Execute all steps in the flow sequentially
          defp run_flow_steps(flow, params, initial_context) do
            # Create initial context with params
            context =
              case initial_context do
                %Flow.Context{} = ctx -> %{ctx | value: params}
                _ -> Flow.Context.new(params)
              end

            # Get initial runnables and execute them
            execute_runnables(flow, context, [])
          end

          # Recursively execute runnables until flow is complete
          defp execute_runnables(flow, context, results) do
            case Flow.next_runnables(flow, context) do
              [] ->
                # No more runnables, flow is complete
                {:ok, %{results: Enum.reverse(results), final_context: context}}

              runnables ->
                # Execute all current runnables
                case execute_runnable_batch(runnables) do
                  {:ok, batch_results} ->
                    # Get the last successful context to continue with
                    last_context = get_last_successful_context(batch_results)
                    execute_runnables(flow, last_context, batch_results ++ results)

                  {:error, _} = error ->
                    error
                end
            end
          end

          # Execute a batch of runnables (could be parallel in the future)
          defp execute_runnable_batch(runnables) do
            results =
              Enum.map(runnables, fn runnable ->
                Flow.run(runnable)
              end)

            # Check if any failed
            case Enum.find(results, fn
                   {:error, _} -> true
                   _ -> false
                 end) do
              {:error, _} = error -> error
              nil -> {:ok, Enum.map(results, fn {:ok, ctx} -> ctx end)}
            end
          end

          # Get the last successful context from a batch of results
          defp get_last_successful_context([]), do: Flow.Context.new(%{})
          defp get_last_successful_context(contexts), do: List.last(contexts)

          # Function to get the stored flow - will be generated by before_compile hook
          # Note: get_flow/0 will be defined by the before_compile hook

          # Default implementation for handle_result
          @impl Jido.Tools.FlowTool
          def handle_result(result) do
            {:ok, result}
          end

          # Allow handle_result to be overridden
          defoverridable handle_result: 1

        {:error, error} ->
          message = Error.format_nimble_config_error(error, "FlowTool", __MODULE__)
          raise CompileError, description: message, file: __ENV__.file, line: __ENV__.line
      end
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    # Get flows captured during compilation
    flows = Module.get_attribute(env.module, :jido_flows) || []
    
    if length(flows) > 0 do
      # Use the first (and likely only) flow
      flow = List.first(flows)
      quote do
        def get_flow do
          unquote(Macro.escape(flow))
        end
      end
    else
      # No flows defined, create a default implementation
      quote do
        def get_flow do
          nil
        end
      end
    end
  end
end
