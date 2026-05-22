defmodule Jido.Exec.Config do
  @moduledoc false

  require Logger

  @doc false
  @spec non_neg_integer(atom(), non_neg_integer()) :: non_neg_integer()
  def non_neg_integer(key, fallback)
      when is_atom(key) and is_integer(fallback) and fallback >= 0 do
    case Application.get_env(:jido_action, key, fallback) do
      value when is_integer(value) and value >= 0 ->
        value

      invalid ->
        Logger.warning(fn ->
          "Invalid :jido_action config for #{inspect(key)}: #{inspect(invalid)}. " <>
            "Expected a non-negative integer; using fallback #{fallback}."
        end)

        fallback
    end
  end
end
