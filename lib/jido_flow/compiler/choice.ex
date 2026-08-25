defmodule Jido.Flow.Compiler.Choice do
  @moduledoc false

  alias Jido.Flow.Choice
  alias Jido.Flow.Compiler.Condition
  alias Jido.Flow.Compiler.Expression
  alias Jido.Flow.Compiler.Target
  alias Jido.Flow.Compiler.TargetContext

  @doc false
  def run(%Choice{} = choice, state) do
    case select_target(choice, state) do
      {:ok, target} ->
        metadata = %{option: target_name(target), target: target.action}

        with {:ok, params} <- Expression.resolve(target.params, state),
             {:ok, output} <-
               Target.run(
                 target.action,
                 params,
                 state.context,
                 TargetContext.choice(choice, target),
                 state.execution_id,
                 state.target_runner
               ) do
          {:ok, output, metadata}
        else
          {:error, error} -> {:error, error, state, metadata}
        end

      {:error, error} ->
        {:error, error, state}
    end
  end

  defp target_name(%Choice.Option{name: name}), do: name
  defp target_name(%Choice.Fallback{}), do: :fallback

  defp select_target(%Choice{} = choice, state) do
    choice.options
    |> Enum.reduce_while({:ok, choice.fallback}, fn option, {:ok, _fallback} ->
      case Condition.evaluate(option.condition, state, choice.name, option.name) do
        {:ok, true} -> {:halt, {:ok, option}}
        {:ok, false} -> {:cont, {:ok, choice.fallback}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end
end
