defmodule Jido.Exec.Flow.Choice do
  @moduledoc false

  alias Jido.Exec.Flow.ValueResolver
  alias Jido.Exec.Flow.Target

  @doc false
  @spec run(map(), map()) :: {:ok, term(), [term()]} | {:error, Exception.t()}
  def run(%{kind: :choice} = choice, state) do
    with {:ok, target} <- select_target(choice, state),
         {_instruction, params_expression} = target.call,
         {:ok, params} <- ValueResolver.resolve(params_expression, state) do
      Target.run(
        Target.at(Target.choice(choice, target), state.namespace),
        params,
        state.context,
        state.execution_id,
        state.target_runner
      )
    end
  end

  defp select_target(choice, state) do
    fallback = %{name: :fallback, call: choice.fallback}

    choice.options
    |> Enum.reduce_while({:ok, fallback}, fn option, {:ok, _fallback} ->
      case ValueResolver.condition(option.condition, state, choice.name, option.name) do
        {:ok, true} -> {:halt, {:ok, option}}
        {:ok, false} -> {:cont, {:ok, fallback}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end
end
