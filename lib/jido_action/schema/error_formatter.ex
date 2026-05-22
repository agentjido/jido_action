defmodule Jido.Action.Schema.ErrorFormatter do
  @moduledoc false

  @doc false
  @spec format_errors([term()]) :: [map()]
  def format_errors(errors) when is_list(errors) do
    Enum.map(errors, fn
      %{path: path, message: message} = error ->
        %{
          path: path,
          message: message,
          code: Map.get(error, :code)
        }

      error ->
        %{message: inspect(error)}
    end)
  end
end
