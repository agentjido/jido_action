defmodule Jido.Flow.Builder.Normalizer do
  @moduledoc false

  alias Jido.Action.Error
  alias Jido.Flow.Iterator.Termination
  alias Jido.Flow.Ref

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
         {:ok, completion, max_iterations} <-
           Termination.normalize(spec, [:while, :until, :repeat]) do
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
end
