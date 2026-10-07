defmodule Jido.Exec.Flow.Choice do
  @moduledoc false

  alias Jido.Flow.Choice
  alias Jido.Exec.Flow.Expression
  alias Jido.Exec.Flow.Target

  @doc false
  @spec run(Choice.t(), map()) :: {:ok, term(), [term()]} | {:error, Exception.t()}
  def run(%Choice{} = choice, state) do
    with {:ok, target} <- select_target(choice, state),
         {:ok, params} <- Expression.resolve(target.params, state) do
      Target.run(
        Target.at(Target.choice(choice, target), state.namespace),
        params,
        state.context,
        state.execution_id,
        state.target_runner
      )
    end
  end

  defp select_target(%Choice{} = choice, state) do
    choice.options
    |> Enum.reduce_while({:ok, choice.fallback}, fn option, {:ok, _fallback} ->
      case Expression.condition(option.condition, state, choice.name, option.name) do
        {:ok, true} -> {:halt, {:ok, option}}
        {:ok, false} -> {:cont, {:ok, choice.fallback}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end
end
