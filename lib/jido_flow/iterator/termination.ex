defmodule Jido.Flow.Iterator.Termination do
  @moduledoc false

  alias Jido.Action.Error
  alias Jido.Flow.Condition
  alias Jido.Flow.Ref

  @maximum_iterations 10_000

  @doc false
  def normalize(spec, supported_forms) when is_map(spec) and is_list(supported_forms) do
    if canonical_termination?(spec) do
      {:ok, Map.fetch!(spec, :completion), Map.fetch!(spec, :max_iterations)}
    else
      normalize_aliases(spec, supported_forms)
    end
  end

  defp canonical_termination?(spec) do
    Map.has_key?(spec, :completion) and Map.has_key?(spec, :max_iterations)
  end

  defp normalize_aliases(spec, supported_forms) do
    forms = Enum.filter(supported_forms, &Map.has_key?(spec, &1))

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
       when is_integer(max_iterations) and max_iterations in 1..@maximum_iterations do
    {:ok, completion, max_iterations}
  end

  defp termination_with_limit(_completion, _max_iterations) do
    {:error,
     Error.validation_error("iterate max_iterations must be an integer from 1 to 10000", %{
       path: [:max_iterations]
     })}
  end

  defp repeat_termination(_count, true) do
    {:error,
     Error.validation_error("iterate with repeat must not set max_iterations", %{
       path: [:max_iterations]
     })}
  end

  defp repeat_termination(count, false)
       when is_integer(count) and count in 1..@maximum_iterations do
    completion = %Condition{
      operator: :gte,
      operands: [Ref.iteration_index(), Ref.value(count)]
    }

    {:ok, completion, count}
  end

  defp repeat_termination(_count, false) do
    {:error,
     Error.validation_error("iterate repeat count must be an integer from 1 to 10000", %{
       path: [:repeat]
     })}
  end
end
