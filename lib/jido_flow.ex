defmodule Jido.Flow do
  @moduledoc """
  A DAG (Directed Acyclic Graph) structure for modeling dataflow dependency pipelines in Jido.

  Jido.Flow builds upon the foundation of Piper but integrates deeply with the Jido.Action
  ecosystem. It supports both function-based steps and Action-based steps, providing
  comprehensive validation, error handling, and execution context management.

  While this maintains compatibility with simple parallelizable job pipelines like those
  in Natural Language Processing, it extends capabilities to include:

  - Integration with Jido.Action modules for robust validation
  - Enhanced error handling and recovery mechanisms  
  - Rich execution context with metadata and error tracking
  - Support for both synchronous and asynchronous execution
  - Pipeline introspection and debugging capabilities

  ## Basic Usage

      # Create a new flow
      flow = Jido.Flow.new("data_processing")

      # Add function-based steps
      flow = 
        flow
        |> Jido.Flow.add_step(name: "normalize", work: &String.downcase/1)
        |> Jido.Flow.add_step("normalize", name: "validate", work: {MyModule, :validate, 1})

      # Add Action-based steps  
      flow = Jido.Flow.add_step(flow, "validate", name: "process", action: MyApp.ProcessAction)

      # Execute with data
      context = Jido.Flow.Context.new("Hello World")
      runnables = Jido.Flow.next_runnables(flow, context)

  ## Action Integration

  Jido.Flow seamlessly integrates with Jido.Action modules:

      defmodule MyApp.ProcessAction do
        use Jido.Action,
          name: "process_data",
          schema: [
            input: [type: :string, required: true]
          ]

        @impl true
        def run(%{input: data}, _context) do
          {:ok, %{result: String.upcase(data)}}
        end
      end

      # Add to flow
      flow = Jido.Flow.add_step(flow, name: "process", action: MyApp.ProcessAction)

  ## Error Handling

  Unlike the original Piper, Jido.Flow provides comprehensive error handling:

      # Contexts can carry errors
      context = 
        Jido.Flow.Context.new("data")
        |> Jido.Flow.Context.add_error(Jido.Action.Error.validation_error("Warning"))

      # Steps handle errors gracefully
      case Jido.Flow.Step.execute(step, context) do
        {:ok, result_context} -> # Success
        {:error, error} -> # Handle failure
      end

  ## Runners

  Different execution strategies can be implemented via runners:

      # Sequential execution
      defmodule SequentialRunner do
        @behaviour Jido.Flow.Runner
        
        def run(runnables) do
          results = Enum.map(runnables, fn {step, context} ->
            Jido.Flow.Step.execute(step, context)
          end)
          {:ok, results}
        end
      end
  """

  use TypedStruct
  
  alias Jido.Flow.{Step, Context}
  alias Jido.Action.Error

  typedstruct do
    field(:name, String.t(), enforce: true)
    field(:flow, Graph.t(), enforce: true)
    field(:metadata, map(), default: %{})
  end

  @type runnable() :: {Step.t(), Context.t()}

  @doc """
  Creates a new Flow with the given name.

  ## Examples

      iex> flow = Jido.Flow.new("my_pipeline")
      iex> flow.name
      "my_pipeline"
      iex> Graph.vertices(flow.flow)
      [:root]
  """
  @spec new(String.t(), map()) :: t()
  def new(name, metadata \\ %{}) when is_binary(name) do
    %__MODULE__{
      name: name,
      flow: Graph.new() |> Graph.add_vertex(:root),
      metadata: metadata
    }
  end

  @doc """
  Executes a step with the given context to produce a new context.

  This is the core execution function that handles both function-based
  and Action-based steps.

  ## Examples

      iex> step = Jido.Flow.Step.new(name: "upper", work: &String.upcase/1)
      iex> context = Jido.Flow.Context.new("hello")
      iex> {:ok, result} = Jido.Flow.run({step, context})
      iex> result.value
      "HELLO"
  """
  @spec run(runnable()) :: {:ok, Context.t()} | {:error, Error.t()}
  def run({%Step{} = step, %Context{} = context}) do
    Step.execute(step, context)
  end

  @doc """
  Returns a list of the next runnables in the Flow pipeline for a given context.

  ## Examples

      iex> flow = Jido.Flow.new("test")
      iex> flow = Jido.Flow.add_step(flow, name: "step1", work: &String.upcase/1)
      iex> context = Jido.Flow.Context.new("hello")
      iex> runnables = Jido.Flow.next_runnables(flow, context)
      iex> length(runnables)
      1
  """
  @spec next_runnables(t(), Context.t()) :: [runnable()]
  def next_runnables(%__MODULE__{flow: flow}, %Context{runnable: {%Step{} = parent_step, _parent_context}} = context) do
    next_steps = Graph.out_neighbors(flow, parent_step)

    Enum.map(next_steps, fn step ->
      {step, Context.clean(context)}
    end)
  end

  def next_runnables(%__MODULE__{flow: flow}, %Context{runnable: nil} = context) do
    next_steps = Graph.out_neighbors(flow, :root)

    Enum.map(next_steps, fn step ->
      {step, context}
    end)
  end

  def next_runnables(%__MODULE__{} = flow, raw_data) do
    context = 
      case raw_data do
        %Context{} = ctx -> ctx
        other -> Context.new(other)
      end
    
    next_runnables(flow, context)
  end

  @doc """
  Adds a step connected directly to the root of the Flow graph.

  This means the given step will always produce a runnable when 
  `next_runnables/2` is called with raw data.

  ## Examples

      iex> flow = Jido.Flow.new("test")
      iex> step = Jido.Flow.Step.new(name: "first", work: &String.upcase/1)
      iex> flow = Jido.Flow.add_step(flow, step)
      iex> steps = Jido.Flow.steps(flow)
      iex> length(steps)
      1
  """
  @spec add_step(t(), Step.t() | keyword()) :: t()
  def add_step(%__MODULE__{flow: flow} = jido_flow, %Step{} = step) do
    %__MODULE__{
      jido_flow
      | flow:
          flow
          |> Graph.add_vertex(step)
          |> Graph.add_edge(:root, step, label: {:root, step.name})
    }
  end

  def add_step(%__MODULE__{} = jido_flow, step_params) when is_list(step_params) do
    add_step(jido_flow, Step.new(step_params))
  end

  @doc """
  Adds a step as a child of an existing step.

  ## Examples

      iex> flow = Jido.Flow.new("test")
      iex> flow = Jido.Flow.add_step(flow, name: "first", work: &String.upcase/1)  
      iex> flow = Jido.Flow.add_step(flow, "first", name: "second", work: &String.reverse/1)
      iex> steps = Jido.Flow.steps(flow)
      iex> length(steps)
      2
  """
  @spec add_step(t(), String.t() | Step.t(), Step.t() | keyword()) :: t()
  def add_step(%__MODULE__{flow: flow} = jido_flow, parent_step_name, %Step{} = child_step)
      when is_binary(parent_step_name) do
    parent_step = get_step_by_name(flow, parent_step_name)
    add_step(jido_flow, parent_step, child_step)
  end

  def add_step(%__MODULE__{flow: flow} = jido_flow, %Step{} = parent_step, %Step{} = child_step) do
    %__MODULE__{
      jido_flow
      | flow:
          flow
          |> Graph.add_vertex(child_step, child_step.name)
          |> Graph.add_edge(parent_step, child_step, label: {parent_step.name, child_step.name})
    }
  end

  def add_step(jido_flow, parent_step_name, child_step_params)
      when is_binary(parent_step_name) and is_list(child_step_params) do
    add_step(jido_flow, parent_step_name, Step.new(child_step_params))
  end

  def add_step(jido_flow, %Step{} = parent_step, child_step_params)
      when is_list(child_step_params) do
    add_step(jido_flow, parent_step, Step.new(child_step_params))
  end

  @doc """
  Returns all steps in the Flow (excluding the root vertex).

  ## Examples

      iex> flow = Jido.Flow.new("test")
      iex> flow = Jido.Flow.add_step(flow, name: "step1", work: &String.upcase/1)
      iex> steps = Jido.Flow.steps(flow)
      iex> length(steps)
      1
      iex> hd(steps).name
      "step1"
  """
  @spec steps(t()) :: [Step.t()]
  def steps(%__MODULE__{flow: flow}) do
    Enum.reject(Graph.vertices(flow), &match?(:root, &1))
  end

  @doc """
  Finds a step by name.

  ## Examples

      iex> flow = Jido.Flow.new("test")
      iex> flow = Jido.Flow.add_step(flow, name: "find_me", work: &String.upcase/1)
      iex> step = Jido.Flow.get_step(flow, "find_me")
      iex> step.name
      "find_me"

      iex> flow = Jido.Flow.new("test")
      iex> Jido.Flow.get_step(flow, "missing")
      nil
  """
  @spec get_step(t(), String.t()) :: Step.t() | nil
  def get_step(%__MODULE__{flow: flow}, name) when is_binary(name) do
    get_step_by_name(flow, name)
  end

  @doc """
  Adds metadata to the flow.

  ## Examples

      iex> flow = Jido.Flow.new("test")
      iex> flow = Jido.Flow.put_meta(flow, :version, "1.0")
      iex> flow.metadata
      %{version: "1.0"}
  """
  @spec put_meta(t(), atom() | String.t(), term()) :: t()
  def put_meta(%__MODULE__{metadata: metadata} = flow, key, value) do
    %{flow | metadata: Map.put(metadata, key, value)}
  end

  @doc """
  Gets metadata from the flow.

  ## Examples

      iex> flow = Jido.Flow.new("test", %{version: "1.0"})
      iex> Jido.Flow.get_meta(flow, :version)
      "1.0"

      iex> flow = Jido.Flow.new("test", %{version: "1.0"})
      iex> Jido.Flow.get_meta(flow, :missing, "default")
      "default"
  """
  @spec get_meta(t(), atom() | String.t(), term()) :: term()
  def get_meta(%__MODULE__{metadata: metadata}, key, default \\ nil) do
    Map.get(metadata, key, default)
  end

  @doc """
  Returns the graph structure for inspection.

  ## Examples

      iex> flow = Jido.Flow.new("test")
      iex> graph = Jido.Flow.graph(flow)
      iex> Graph.vertices(graph)
      [:root]
  """
  @spec graph(t()) :: Graph.t()
  def graph(%__MODULE__{flow: flow}), do: flow

  @doc """
  Checks if the flow has any cycles (should always be false for valid DAGs).

  ## Examples

      iex> flow = Jido.Flow.new("test")
      iex> flow = Jido.Flow.add_step(flow, name: "step1", work: &String.upcase/1)
      iex> Jido.Flow.acyclic?(flow)
      true
  """
  @spec acyclic?(t()) :: boolean()
  def acyclic?(%__MODULE__{flow: flow}) do
    Graph.is_acyclic?(flow)
  end

  @doc """
  Returns topological ordering of steps.

  ## Examples

      iex> flow = Jido.Flow.new("test")
      iex> flow = Jido.Flow.add_step(flow, name: "first", work: &String.upcase/1)
      iex> flow = Jido.Flow.add_step(flow, "first", name: "second", work: &String.reverse/1)
      iex> order = Jido.Flow.topological_order(flow)
      iex> length(order)
      2
  """
  @spec topological_order(t()) :: [Step.t()]
  def topological_order(%__MODULE__{flow: flow}) do
    flow
    |> Graph.topsort()
    |> Enum.reject(&match?(:root, &1))
  end

  # Private helper functions

  defp get_step_by_name(flow, name) do
    Enum.find(Graph.vertices(flow), nil, fn
      %Step{name: step_name} -> step_name == name
      :root -> false
    end)
  end
end
