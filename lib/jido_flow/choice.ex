defmodule Jido.Flow.Choice do
  @moduledoc """
  A named, ordered Flow choice with a required fallback target.

  Options are evaluated in authored order. The first true condition selects
  its action. The fallback action is selected when no option matches. Only the
  selected target input is resolved and only the selected target runs.

  A Choice is one Flow node. Its output becomes the Choice node result for
  downstream references. The fallback is a routing fallback, not error
  recovery for a selected target.

  This is a read-only canonical type. Create it through the Flow module DSL,
  `Jido.Flow.Builder`, or the stored Flow decoder.
  """

  alias Jido.Action.Error
  alias Jido.Flow.Condition
  alias Jido.Flow.Element.Validation, as: ElementValidation
  alias Jido.Flow.Expression
  alias Jido.Instruction

  @config_keys [:name, :options, :fallback, :deps, :provenance]

  @type option :: %{
          required(:name) => String.t(),
          required(:condition) => Condition.t(),
          required(:action) => module(),
          required(:input) => term()
        }

  @type fallback :: %{
          required(:name) => :fallback,
          required(:action) => module(),
          required(:input) => term()
        }

  @type t :: %__MODULE__{
          name: String.t(),
          options: [option()],
          fallback: fallback(),
          deps: [String.t()],
          provenance: map()
        }

  @enforce_keys [:name, :options, :fallback, :deps, :provenance]
  defstruct [:name, :options, :fallback, :deps, :provenance]

  defmodule Option do
    @moduledoc false

    @type t :: %__MODULE__{
            name: String.t(),
            condition: Jido.Flow.Condition.t(),
            action: module(),
            input: term()
          }

    @enforce_keys [:name, :condition, :action, :input]
    defstruct [:name, :condition, :action, :input]
  end

  defmodule Fallback do
    @moduledoc false

    @type t :: %__MODULE__{name: :fallback, action: module(), input: term()}

    @enforce_keys [:name, :action, :input]
    defstruct [:name, :action, :input]
  end

  @doc false
  @spec new(map() | keyword() | t()) :: {:ok, t()} | {:error, Exception.t()}
  def new(%__MODULE__{} = choice), do: choice |> Map.from_struct() |> new()

  def new(attrs) when is_list(attrs) do
    if Keyword.keyword?(attrs),
      do: attrs |> Map.new() |> new(),
      else: {:error, Error.validation_error("choice configuration must be a map", %{path: []})}
  end

  def new(%{} = attrs) do
    with :ok <- ElementValidation.known_keys(attrs, @config_keys, "choice"),
         {:ok, name} <- ElementValidation.name(Map.get(attrs, :name), :choice, []),
         {:ok, options} <- validate_options(Map.get(attrs, :options), [:options]),
         {:ok, fallback} <- validate_fallback(Map.get(attrs, :fallback), [:fallback]),
         {:ok, deps} <- ElementValidation.deps(Map.get(attrs, :deps, []), :choice),
         {:ok, provenance} <-
           ElementValidation.provenance(Map.get(attrs, :provenance, %{}), :choice) do
      {:ok,
       %__MODULE__{
         name: name,
         options: options,
         fallback: fallback,
         deps: deps,
         provenance: provenance
       }}
    end
  end

  def new(_attrs),
    do: {:error, Error.validation_error("choice configuration must be a map", %{path: []})}

  @doc false
  @spec new!(map() | keyword() | t()) :: t() | no_return()
  def new!(attrs) do
    case new(attrs) do
      {:ok, choice} -> choice
      {:error, error} -> raise error
    end
  end

  @doc false
  @spec result_deps(t()) :: [String.t()]
  def result_deps(%__MODULE__{} = choice) do
    choice.options
    |> Enum.flat_map(fn option ->
      Condition.result_deps(option.condition) ++ Expression.result_refs(option.input)
    end)
    |> Kernel.++(Expression.result_refs(choice.fallback.input))
    |> Kernel.++(choice.deps)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc false
  @spec put_deps(t(), [String.t()]) :: t()
  def put_deps(%__MODULE__{} = choice, deps), do: %{choice | deps: deps}

  @doc false
  @spec check(t()) :: :ok | {:error, Exception.t()}
  def check(%__MODULE__{} = choice) do
    choice.options
    |> Enum.reduce_while(:ok, fn option, :ok ->
      case validate_target_contract(option.action, choice.name, option.name) do
        :ok -> {:cont, :ok}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      :ok -> validate_target_contract(choice.fallback.action, choice.name, :fallback)
      {:error, error} -> {:error, error}
    end
  end

  @doc false
  @spec targets(t()) :: [{String.t() | :fallback, module()}]
  def targets(%__MODULE__{} = choice) do
    Enum.map(choice.options, &{&1.name, &1.action}) ++ [{:fallback, choice.fallback.action}]
  end

  @doc false
  @spec to_map(t(), keyword()) :: map()
  def to_map(%__MODULE__{} = choice, opts \\ []) do
    base = %{
      kind: :choice,
      name: choice.name,
      options:
        Enum.map(choice.options, fn option ->
          %{
            name: option.name,
            condition: Condition.to_map(option.condition),
            action: option.action,
            input: Expression.to_map(option.input)
          }
        end),
      fallback: %{
        name: :fallback,
        action: choice.fallback.action,
        input: Expression.to_map(choice.fallback.input)
      },
      deps: Enum.sort(choice.deps)
    }

    if Keyword.get(opts, :provenance, false) do
      Map.put(base, :provenance, choice.provenance)
    else
      base
    end
  end

  @doc false
  @spec static_data(t()) :: map()
  def static_data(%__MODULE__{} = choice) do
    %{
      name: choice.name,
      options:
        Enum.map(choice.options, fn option ->
          %{
            name: option.name,
            condition: Condition.to_map(option.condition),
            action: option.action,
            input: option.input
          }
        end),
      fallback: %{name: :fallback, action: choice.fallback.action, input: choice.fallback.input},
      deps: choice.deps
    }
  end

  @doc false
  @spec semantic_data(t()) :: map()
  def semantic_data(%__MODULE__{} = choice), do: static_data(choice)

  defp validate_options(options, _path) when not is_list(options) do
    {:error, Error.validation_error("choice options must be a list", %{path: [:options]})}
  end

  defp validate_options([], _path) do
    {:error,
     Error.validation_error("choice options must contain at least one option", %{path: []})}
  end

  defp validate_options(options, path) do
    if List.improper?(options) do
      {:error, Error.validation_error("choice options must be a proper list", %{path: path})}
    else
      validate_proper_options(options, path)
    end
  end

  defp validate_proper_options(options, path) do
    options
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {attrs, index}, {:ok, acc} ->
      case validate_option(attrs, path ++ [index]) do
        {:ok, option} -> {:cont, {:ok, [option | acc]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> normalize_options()
  end

  defp normalize_options({:ok, options}) do
    options = Enum.reverse(options)

    case duplicate_option_name(options) do
      nil ->
        {:ok, options}

      {name, index} ->
        {:error,
         Error.validation_error("duplicate choice option name: #{inspect(name)}", %{
           path: [:options, index, :name],
           name: name
         })}
    end
  end

  defp normalize_options({:error, error}), do: {:error, error}

  defp validate_option(%Option{} = option, path),
    do: option |> Map.from_struct() |> validate_option(path)

  defp validate_option(attrs, path) when is_list(attrs) do
    if Keyword.keyword?(attrs),
      do: attrs |> Map.new() |> validate_option(path),
      else: {:error, Error.validation_error("choice option must be a map", %{path: path})}
  end

  defp validate_option(%{} = attrs, path) do
    with :ok <-
           ElementValidation.known_keys(
             attrs,
             [:name, :condition, :action, :input],
             "choice option",
             path
           ),
         {:ok, name} <- ElementValidation.name(Map.get(attrs, :name), :choice, path ++ [:name]),
         {:ok, condition} <- validate_condition(Map.get(attrs, :condition), path ++ [:condition]),
         {:ok, action} <-
           ElementValidation.target(
             Map.get(attrs, :action),
             {:label, "choice option"},
             path ++ [:action]
           ),
         {:ok, input} <- validate_input(Map.get(attrs, :input, %{}), path ++ [:input]) do
      {:ok, %Option{name: name, condition: condition, action: action, input: input}}
    end
  end

  defp validate_option(_attrs, path) do
    {:error, Error.validation_error("choice option must be a map", %{path: path})}
  end

  defp validate_fallback(nil, path) do
    {:error, Error.validation_error("choice fallback is required", %{path: path})}
  end

  defp validate_fallback(%Fallback{name: :fallback} = fallback, path) do
    fallback
    |> Map.from_struct()
    |> Map.delete(:name)
    |> validate_fallback(path)
  end

  defp validate_fallback(%Fallback{}, path) do
    {:error,
     Error.validation_error("choice fallback name must be :fallback", %{path: path ++ [:name]})}
  end

  defp validate_fallback(attrs, path) when is_list(attrs) do
    if Keyword.keyword?(attrs),
      do: attrs |> Map.new() |> validate_fallback(path),
      else: {:error, Error.validation_error("choice fallback must be a map", %{path: path})}
  end

  defp validate_fallback(%{} = attrs, path) do
    with :ok <- ElementValidation.known_keys(attrs, [:action, :input], "choice fallback", path),
         {:ok, action} <-
           ElementValidation.target(
             Map.get(attrs, :action),
             {:label, "choice fallback"},
             path ++ [:action]
           ),
         {:ok, input} <- validate_input(Map.get(attrs, :input, %{}), path ++ [:input]) do
      {:ok, %Fallback{name: :fallback, action: action, input: input}}
    end
  end

  defp validate_fallback(_attrs, path) do
    {:error, Error.validation_error("choice fallback must be a map", %{path: path})}
  end

  defp validate_condition(%Condition{} = condition, path) do
    case Condition.new(condition) do
      {:ok, condition} -> {:ok, condition}
      {:error, error} -> {:error, prefix_error_path(error, path)}
    end
  end

  defp validate_condition(_condition, path) do
    {:error,
     Error.validation_error("choice option condition must be a Jido.Flow.Condition", %{path: path})}
  end

  defp validate_input(nil, _path), do: {:ok, %{}}

  defp validate_input(input, path) do
    ElementValidation.expression(input, :flow, "choice target input", path, static: true)
  end

  defp duplicate_option_name(options) do
    options
    |> Enum.with_index()
    |> Enum.reduce_while(MapSet.new(), fn {%Option{name: name}, index}, seen ->
      if MapSet.member?(seen, name) do
        {:halt, {name, index}}
      else
        {:cont, MapSet.put(seen, name)}
      end
    end)
    |> case do
      %MapSet{} -> nil
      duplicate -> duplicate
    end
  end

  defp validate_target_contract(action, choice, option) do
    case Instruction.validate_action_contract(action) do
      :ok ->
        :ok

      {:error, error} ->
        {:error,
         Error.validation_error(
           error.message,
           %{
             choice: choice,
             option: option,
             target: action
           }
           |> Map.merge(error.details)
         )}
    end
  end

  defp prefix_error_path(%{details: details} = error, prefix) when is_map(details) do
    %{error | details: Map.put(details, :path, prefix ++ Map.get(details, :path, []))}
  end

  defp prefix_error_path(error, _prefix), do: error
end
