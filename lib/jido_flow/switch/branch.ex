defmodule Jido.Flow.Switch.Branch do
  @moduledoc false

  @type default_branch :: %{
          required(:flow) => [map()],
          required(:return) => term()
        }

  @doc false
  @spec default?(term()) :: boolean()
  def default?(%{flow: flow, return: _return} = default) when is_list(flow),
    do: exact_default_keys?(default)

  def default?(_default), do: false

  @doc false
  @spec flow?(term()) :: boolean()
  def flow?(%{flow: flow}) when is_list(flow), do: true
  def flow?(_match), do: false

  @doc false
  @spec validate_match(term()) :: :ok | {:error, String.t()}
  def validate_match(%{then: _target, flow: _flow}),
    do: {:error, "switch matches must contain only one of then or flow"}

  def validate_match(%{then: _target}), do: :ok
  def validate_match(%{flow: flow}), do: validate_flow(flow)

  def validate_match(_match),
    do: {:error, "switch matches must contain then or flow"}

  @doc false
  @spec validate_default(term()) :: :ok | {:error, String.t()}
  def validate_default(nil), do: :ok

  def validate_default(%{flow: flow, return: _return} = default) do
    if exact_default_keys?(default) do
      validate_flow(flow)
    else
      :ok
    end
  end

  def validate_default(_default), do: :ok

  @doc false
  @spec validate_flow(term()) :: :ok | {:error, String.t()}
  def validate_flow(nil), do: :ok
  def validate_flow(flow) when is_list(flow), do: :ok
  def validate_flow(_flow), do: {:error, "switch branch flow must be a list"}

  defp exact_default_keys?(default), do: default |> Map.keys() |> Enum.sort() == [:flow, :return]
end
