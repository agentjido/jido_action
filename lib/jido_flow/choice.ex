defmodule Jido.Flow.Choice do
  @moduledoc """
  A named, ordered Flow choice with a required fallback target.
  """

  alias Jido.Action
  alias Jido.Action.Error
  alias Jido.Flow.Condition
  alias Jido.Flow.Node
  alias Jido.Instruction

  @config_keys [:name, :options, :fallback, :deps, :provenance]

  @type t :: %__MODULE__{
          name: String.t(),
          options: [Option.t()],
          fallback: Fallback.t(),
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

  @doc """
  Builds a Choice from keyword or map attributes.
  """
  @spec new(map() | keyword() | t()) :: {:ok, t()} | {:error, Exception.t()}
  def new(%__MODULE__{} = choice), do: choice |> Map.from_struct() |> new()
  def new(attrs) when is_list(attrs), do: attrs |> Map.new() |> new()

  def new(%{} = attrs) do
    with :ok <- validate_known_keys(attrs),
         {:ok, name} <- validate_name(Map.get(attrs, :name), []),
         {:ok, options} <- validate_options(Map.get(attrs, :options), [:options]),
         {:ok, fallback} <- validate_fallback(Map.get(attrs, :fallback), [:fallback]),
         {:ok, deps} <- validate_deps(Map.get(attrs, :deps, []), [:deps]),
         {:ok, provenance} <- validate_provenance(Map.get(attrs, :provenance, %{})) do
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

  @doc """
  Builds a Choice or raises on validation failure.
  """
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
      Condition.result_deps(option.condition) ++ Node.collect_result_refs(option.input)
    end)
    |> Kernel.++(Node.collect_result_refs(choice.fallback.input))
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
            input: Node.expression_to_map(option.input)
          }
        end),
      fallback: %{
        name: :fallback,
        action: choice.fallback.action,
        input: Node.expression_to_map(choice.fallback.input)
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
  @spec semantic_data(t()) :: map()
  def semantic_data(%__MODULE__{} = choice) do
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

  defp validate_options(options, _path) when not is_list(options) do
    {:error, Error.validation_error("choice options must be a list", %{path: [:options]})}
  end

  defp validate_options([], _path) do
    {:error,
     Error.validation_error("choice options must contain at least one option", %{path: []})}
  end

  defp validate_options(options, path) do
    options
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {attrs, index}, {:ok, acc} ->
      case validate_option(attrs, path ++ [index]) do
        {:ok, option} -> {:cont, {:ok, [option | acc]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, options} ->
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

      {:error, error} ->
        {:error, error}
    end
  end

  defp validate_option(%Option{} = option, path),
    do: option |> Map.from_struct() |> validate_option(path)

  defp validate_option(attrs, path) when is_list(attrs),
    do: attrs |> Map.new() |> validate_option(path)

  defp validate_option(%{} = attrs, path) do
    with :ok <-
           validate_known_keys(attrs, [:name, :condition, :action, :input], "choice option", path),
         {:ok, name} <- validate_name(Map.get(attrs, :name), path ++ [:name]),
         {:ok, condition} <- validate_condition(Map.get(attrs, :condition), path ++ [:condition]),
         {:ok, action} <-
           validate_target(Map.get(attrs, :action), "choice option", path ++ [:action]),
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

  defp validate_fallback(attrs, path) when is_list(attrs),
    do: attrs |> Map.new() |> validate_fallback(path)

  defp validate_fallback(%{} = attrs, path) do
    with :ok <- validate_known_keys(attrs, [:action, :input], "choice fallback", path),
         {:ok, action} <-
           validate_target(Map.get(attrs, :action), "choice fallback", path ++ [:action]),
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

  defp validate_target(target, _owner, _path) when is_atom(target) and not is_nil(target),
    do: {:ok, target}

  defp validate_target(_target, owner, path) do
    {:error, Error.validation_error("#{owner} target must be a module atom", %{path: path})}
  end

  defp validate_input(nil, _path), do: {:ok, %{}}

  defp validate_input(input, path) do
    with {:ok, input} <- Node.normalize_expression(input),
         :ok <- Node.validate_expression(input),
         :ok <- validate_static_input(input) do
      {:ok, input}
    else
      {:error, error} -> {:error, translate_input_error(error, path)}
    end
  end

  defp validate_static_input(input) do
    case Action.validate_static_data(input) do
      :ok -> :ok
      {:error, _reason} -> {:error, Error.validation_error("choice target input is not static")}
    end
  end

  defp validate_deps(nil, _path), do: {:ok, []}

  defp validate_deps(deps, _path) when is_list(deps) do
    deps
    |> Enum.reduce_while({:ok, []}, fn dep, {:ok, acc} ->
      case validate_name(dep, [:deps]) do
        {:ok, dep} ->
          {:cont, {:ok, [dep | acc]}}

        {:error, _error} ->
          {:halt,
           {:error,
            Error.validation_error("choice deps must be a list of step names", %{path: [:deps]})}}
      end
    end)
    |> case do
      {:ok, deps} -> {:ok, deps |> Enum.uniq() |> Enum.sort()}
      {:error, error} -> {:error, error}
    end
  end

  defp validate_deps(_deps, _path) do
    {:error, Error.validation_error("choice deps must be a list", %{path: [:deps]})}
  end

  defp validate_provenance(nil), do: {:ok, %{}}
  defp validate_provenance(provenance) when is_map(provenance), do: {:ok, provenance}

  defp validate_provenance(_provenance) do
    {:error, Error.validation_error("choice provenance must be a map", %{path: [:provenance]})}
  end

  defp validate_name(name, path) when is_atom(name) and not is_nil(name),
    do: name |> Atom.to_string() |> validate_name(path)

  defp validate_name(name, path) when is_binary(name) do
    case Action.validate_name(name) do
      :ok -> {:ok, name}
      {:error, message} -> {:error, Error.validation_error(message, %{path: path})}
    end
  end

  defp validate_name(_name, path) do
    {:error,
     Error.validation_error("choice name must be a non-empty string or atom", %{path: path})}
  end

  defp validate_known_keys(attrs) do
    validate_known_keys(attrs, @config_keys, "choice", [])
  end

  defp validate_known_keys(attrs, allowed, owner, path) do
    case attrs |> Map.keys() |> Enum.find(&(&1 not in allowed)) do
      nil ->
        :ok

      key ->
        {:error,
         Error.validation_error("unknown #{owner} configuration key: #{inspect(key)}", %{
           path: path ++ [key],
           key: key
         })}
    end
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

  defp translate_input_error(error, path) do
    details = Map.get(error, :details, %{})
    nested_path = path ++ Map.get(details, :path, [])

    case Node.expression_error_kind(error) do
      :invalid_ref_path ->
        Error.validation_error("choice target input contains invalid ref path", %{
          path: nested_path,
          segment: details.segment
        })

      :invalid_ref ->
        Error.validation_error("choice target input contains invalid ref", %{
          path: nested_path,
          type: details.type
        })

      :unsupported_expression ->
        Error.validation_error("choice target input contains unsupported expression", %{
          path: nested_path,
          expression: details.expression
        })

      :other ->
        Error.validation_error("choice target input must be static module data", %{path: path})
    end
  end

  defp prefix_error_path(%{details: details} = error, prefix) when is_map(details) do
    %{error | details: Map.put(details, :path, prefix ++ Map.get(details, :path, []))}
  end

  defp prefix_error_path(error, _prefix), do: error
end
