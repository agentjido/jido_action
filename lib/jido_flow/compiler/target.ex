defmodule Jido.Flow.Compiler.Target do
  @moduledoc false

  alias Jido.Flow.Compiler.ErrorTagger

  @doc false
  def run(action, params, context, owner, execution_id, target_runner) do
    case target_runner.(action, params, context, execution_id) do
      {:ok, output} ->
        {:ok, output}

      {:error, :input, error} ->
        ErrorTagger.tag_target_validation_error({:error, error}, :input, owner)

      {:error, phase, error} when phase in [:execution, :output] ->
        ErrorTagger.tag_target_error({:error, error}, phase, owner)
    end
  end
end
