defmodule Jido.Flow.Identity do
  @moduledoc false

  import Bitwise

  alias Jido.Flow

  @identity_version 1
  @step_identity_version 1

  @doc false
  @spec semantic_digest(Flow.t()) :: String.t()
  def semantic_digest(%Flow{} = flow) do
    flow
    |> Flow.to_map()
    |> identity()
    |> Map.fetch!(:digest)
  end

  @doc false
  @spec identity(map()) :: %{
          version: 1,
          algorithm: :sha256,
          digest: String.t(),
          uuid: String.t()
        }
  def identity(canonical_identity_map) when is_map(canonical_identity_map) do
    raw_digest =
      {:jido_flow_identity, @identity_version, canonical_identity_map}
      |> hash_term()

    %{
      version: @identity_version,
      algorithm: :sha256,
      digest: Base.encode16(raw_digest, case: :lower),
      uuid: uuid_v8(raw_digest)
    }
  end

  @doc false
  @spec step_uuid(String.t(), String.t()) :: String.t()
  def step_uuid(flow_digest, node_name)
      when is_binary(flow_digest) and is_binary(node_name) do
    {:jido_flow_step_identity, @step_identity_version, flow_digest, node_name}
    |> hash_term()
    |> uuid_v8()
  end

  @doc false
  @spec hash_term(term()) :: binary()
  def hash_term(term) do
    term
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
  end

  @doc false
  @spec uuid_v8(binary()) :: String.t()
  def uuid_v8(
        <<time_low::32, time_mid::16, version_bits::16, variant_bits::16, node::48, _::binary>>
      ) do
    version_bits = bor(band(version_bits, 0x0FFF), 0x8000)
    variant_bits = bor(band(variant_bits, 0x3FFF), 0x8000)

    :io_lib.format(
      ~c"~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b",
      [time_low, time_mid, version_bits, variant_bits, node]
    )
    |> IO.iodata_to_binary()
  end
end
