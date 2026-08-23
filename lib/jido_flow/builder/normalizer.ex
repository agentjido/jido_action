defmodule Jido.Flow.Builder.Normalizer do
  @moduledoc false

  alias Jido.Action.Error
  alias Jido.Flow.{Condition, Ref}

  @doc false
  def normalize(specs) do
    specs
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {spec, index}, {:ok, normalized} ->
      case normalize_node_spec(spec) do
        {:ok, spec} -> {:cont, {:ok, [spec | normalized]}}
        {:error, error} -> {:halt, {:error, prefix_path(error, [:nodes, index])}}
      end
    end)
    |> reverse_ok()
  end

  defp normalize_node_spec(%{
         kind: kind,
         __builder_options_error__: %{reason: :unsupported, options: options}
       }) do
    {:error,
     Error.validation_error("Builder #{kind} received unsupported options", %{
       options: options,
       path: [:options]
     })}
  end

  defp normalize_node_spec(%{__builder_options_error__: error}) do
    {:error,
     Error.validation_error(
       "Builder node options must be a keyword list with unique keys",
       %{
         options: Map.get(error, :options),
         path: [:options]
       }
     )}
  end

  defp normalize_node_spec(%{kind: :iterate} = spec) do
    with {:ok, spec} <- normalize_common_aliases(spec),
         {:ok, state} <- normalize_state(Map.get(spec, :state)),
         {:ok, completion, max_iterations} <- normalize_termination(spec) do
      {:ok,
       spec
       |> Map.drop([:while, :until, :repeat])
       |> Map.put(:state, state)
       |> Map.put(:completion, completion)
       |> Map.put(:max_iterations, max_iterations)}
    end
  end

  defp normalize_node_spec(spec), do: normalize_common_aliases(spec)

  defp normalize_common_aliases(spec) do
    with {:ok, deps} <- normalize_after(Map.get(spec, :after, Map.get(spec, :deps, []))),
         {:ok, provenance} <- normalize_provenance(spec) do
      {:ok,
       spec
       |> Map.drop([:after, :meta])
       |> Map.put(:deps, deps)
       |> Map.put(:provenance, provenance)}
    end
  end

  defp normalize_state(%{__struct__: _module} = state), do: {:ok, state}

  defp normalize_state(%{} = state) do
    {:ok, Map.put_new(state, :update, Ref.body_result())}
  end

  defp normalize_state(state) when is_list(state) do
    if Keyword.keyword?(state),
      do: state |> Map.new() |> normalize_state(),
      else: {:error, Error.validation_error("iterator state configuration must be a map")}
  end

  defp normalize_state(state), do: {:ok, state}

  defp normalize_termination(%{completion: completion, max_iterations: max_iterations}) do
    {:ok, completion, max_iterations}
  end

  defp normalize_termination(spec) do
    forms = Enum.filter([:while, :until, :repeat], &Map.has_key?(spec, &1))

    case forms do
      [:until] ->
        termination_with_limit(Map.fetch!(spec, :until), Map.get(spec, :max_iterations))

      [:while] ->
        completion = %Condition{operator: :not, operands: [Map.fetch!(spec, :while)]}
        termination_with_limit(completion, Map.get(spec, :max_iterations))

      [:repeat] ->
        repeat_termination(Map.fetch!(spec, :repeat), Map.has_key?(spec, :max_iterations))

      _forms ->
        {:error,
         Error.validation_error("iterate requires exactly one of while, until, or repeat")}
    end
  end

  defp termination_with_limit(completion, max_iterations)
       when is_integer(max_iterations) and max_iterations >= 1 and max_iterations <= 10_000 do
    {:ok, completion, max_iterations}
  end

  defp termination_with_limit(_completion, _max_iterations) do
    {:error,
     Error.validation_error(
       "iterate max_iterations must be an integer from 1 to 10000",
       %{path: [:max_iterations]}
     )}
  end

  defp repeat_termination(_count, true) do
    {:error,
     Error.validation_error("iterate with repeat must not set max_iterations", %{
       path: [:max_iterations]
     })}
  end

  defp repeat_termination(count, false)
       when is_integer(count) and count >= 1 and count <= 10_000 do
    completion = %Condition{
      operator: :gte,
      operands: [Ref.iteration_index(), Ref.value(count)]
    }

    {:ok, completion, count}
  end

  defp repeat_termination(_count, false) do
    {:error,
     Error.validation_error(
       "iterate repeat count must be an integer from 1 to 10000",
       %{path: [:repeat]}
     )}
  end

  defp normalize_after(nil), do: {:ok, []}

  defp normalize_after(after_targets) when is_list(after_targets) do
    if List.improper?(after_targets) do
      {:error, Error.validation_error("flow node dependencies must be a proper list")}
    else
      {:ok, after_targets}
    end
  end

  defp normalize_after(after_target), do: {:ok, [after_target]}

  defp normalize_provenance(spec) do
    provenance = Map.get(spec, :provenance, Map.get(spec, :meta, %{}))

    if is_map(provenance) do
      {:ok, provenance}
    else
      {:error, Error.validation_error("flow node metadata must be a map", %{path: [:meta]})}
    end
  end

  defp reverse_ok({:ok, values}), do: {:ok, Enum.reverse(values)}
  defp reverse_ok({:error, error}), do: {:error, error}

  defp prefix_path(%{details: details} = error, prefix) when is_map(details) do
    %{error | details: Map.put(details, :path, prefix ++ Map.get(details, :path, []))}
  end

  defp prefix_path(error, _prefix), do: error
end
