defmodule Jido.Exec.Budget do
  @moduledoc false

  @doc false
  @spec remaining(map()) :: non_neg_integer() | :infinity | nil
  def remaining(%{__jido_exec__: %{deadline: deadline}}) when is_integer(deadline),
    do: max(deadline - System.monotonic_time(:millisecond), 0)

  def remaining(%{__jido_exec__: %{deadline: :infinity}}), do: :infinity
  def remaining(context) when is_map(context), do: nil

  @doc false
  @spec attach(term(), integer() | :infinity) :: {:ok, term()} | {:error, Exception.t()}
  def attach(nil, deadline), do: attach(%{}, deadline)

  def attach(context, deadline) when is_list(context) do
    if Keyword.keyword?(context), do: attach(Map.new(context), deadline), else: {:ok, context}
  end

  def attach(context, deadline) when is_map(context) do
    case Map.fetch(context, :__jido_exec__) do
      :error ->
        {:ok, Map.put(context, :__jido_exec__, %{deadline: deadline})}

      {:ok, %{deadline: inherited} = metadata}
      when is_integer(inherited) or inherited == :infinity ->
        {:ok,
         Map.put(context, :__jido_exec__, %{metadata | deadline: earliest(inherited, deadline)})}

      {:ok, _invalid} ->
        {:error,
         Jido.Action.Error.validation_error(
           "context.__jido_exec__ must contain an integer or :infinity deadline",
           %{field: :__jido_exec__}
         )}
    end
  end

  # Leave invalid context types to the existing Action or Flow boundary.
  def attach(context, _deadline), do: {:ok, context}

  defp earliest(left, right) when is_integer(left) and is_integer(right), do: min(left, right)
  defp earliest(left, _right) when is_integer(left), do: left
  defp earliest(_left, right) when is_integer(right), do: right
  defp earliest(_left, _right), do: :infinity
end
