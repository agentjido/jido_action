defmodule Jido.Flow.Compiler.Choice do
  @moduledoc false

  alias Jido.Flow.Choice
  alias Jido.Flow.Compiler.Condition
  alias Jido.Flow.Compiler.ErrorTagger
  alias Jido.Flow.Compiler.Expression
  alias Jido.Flow.Compiler.Target

  @doc false
  def run(%Choice{} = choice, state) do
    case select_target(choice, state) do
      {:ok, target} ->
        metadata = %{option: target.name, target: target.action}

        with {:ok, params} <- Expression.resolve(target.input, state),
             {:ok, output} <-
               Target.run(
                 target.action,
                 params,
                 state.context,
                 ErrorTagger.choice_target_owner(choice, target),
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
