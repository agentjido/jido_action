defmodule Jido.Flow.MapCodec do
  @moduledoc false

  alias Jido.Action.Error
  alias Jido.Flow.Constructor
  alias Jido.Flow.MapCodec.Decoder
  alias Jido.Flow.MapCodec.Encoder
  alias Jido.Flow.MapCodec.ErrorPath
  alias Jido.Flow.Registry

  @spec to_stored_map!(Jido.Flow.t(), [Jido.Flow.Element.t()], Registry.t(), keyword()) :: map()
  def to_stored_map!(flow, ordered_nodes, %Registry{} = registry, opts) do
    Encoder.to_stored_map!(flow, ordered_nodes, registry, opts)
  end

  @spec to_stored_map(Jido.Flow.t(), [Jido.Flow.Element.t()], Registry.t(), keyword()) ::
          {:ok, map()} | {:error, Error.InvalidInputError.t()}
  def to_stored_map(flow, ordered_nodes, %Registry{} = registry, opts) do
    Encoder.to_stored_map(flow, ordered_nodes, registry, opts)
  end

  def to_stored_map(_flow, _ordered_nodes, registry, _opts) do
    ErrorPath.error("stored flow requires a Jido.Flow.Registry", %{registry: inspect(registry)})
  end

  @spec from_stored_map(map(), Registry.t()) ::
          {:ok, Jido.Flow.t()} | {:error, Exception.t()}
  def from_stored_map(%{} = map, %Registry{} = registry) do
    with {:ok, attrs} <- Decoder.decode(map, registry) do
      Constructor.build(attrs)
    end
  end

  def from_stored_map(map, %Registry{}) when not is_map(map) do
    ErrorPath.error("flow map must be a map")
  end

  def from_stored_map(_map, registry) do
    ErrorPath.error("stored flow requires a Jido.Flow.Registry", %{registry: inspect(registry)})
  end
end
