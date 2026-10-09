defmodule Jido.Exec.Fact.LocalValue do
  @moduledoc false

  @enforce_keys [:value, :digest]
  defstruct [:value, :digest]

  @type t :: %__MODULE__{value: term(), digest: binary()}
end

defimpl Runic.Identity.Projectable, for: Jido.Exec.Fact.LocalValue do
  def identity_document(local_value) do
    %{codec: :jido_local_term, digest: local_value.digest}
  end
end

defmodule Jido.Exec.Fact do
  @moduledoc false

  alias Jido.Exec.Fact.LocalValue
  alias Runic.Identity
  alias Runic.Workflow.Fact

  @local_identity %{jido: %{identity_mode: :local}}
  @max_local_depth 32

  @doc false
  @spec local_root(term()) :: Fact.t()
  def local_root(value) do
    Fact.new(value: wrap(value), meta: @local_identity)
  end

  @doc false
  @spec child(Fact.t(), keyword()) :: Fact.t()
  def child(%Fact{} = parent, opts) do
    if local?(parent) do
      opts
      |> Keyword.update!(:value, &wrap/1)
      |> Keyword.update(:meta, @local_identity, &put_local_identity/1)
      |> Fact.new()
    else
      Fact.new(opts)
    end
  end

  @doc false
  @spec value(Fact.t()) :: term()
  def value(%Fact{value: value}), do: unwrap(value)

  @doc false
  @spec decode_value(term()) :: term()
  def decode_value(value), do: unwrap(value)

  @doc false
  @spec encode_output(term(), term(), map()) :: {term(), map()}
  def encode_output(value, input, metadata) do
    if match?(%{jido: %{identity_mode: :local}}, metadata) or contains_local_value?(input) do
      {wrap(value), put_local_identity(metadata)}
    else
      {value, metadata}
    end
  end

  defp local?(%Fact{meta: %{jido: %{identity_mode: :local}}}), do: true
  defp local?(%Fact{value: value}), do: contains_local_value?(value)

  defp put_local_identity(meta) do
    Map.update(meta, :jido, %{identity_mode: :local}, &Map.put(&1, :identity_mode, :local))
  end

  defp wrap(value), do: wrap(value, 0)

  defp wrap(value, _depth)
       when is_nil(value) or is_boolean(value) or is_integer(value) or is_float(value) or
              is_binary(value) or is_atom(value),
       do: value

  defp wrap(%Identity{} = value, _depth), do: value
  defp wrap(%LocalValue{} = value, _depth), do: value
  defp wrap(value, depth) when depth >= @max_local_depth, do: local_value(value)

  defp wrap(%_{} = value, _depth) do
    if portable_struct?(value), do: value, else: local_value(value)
  end

  defp wrap(value, depth) when is_list(value) do
    if List.improper?(value), do: local_value(value), else: Enum.map(value, &wrap(&1, depth + 1))
  end

  defp wrap(value, depth) when is_tuple(value) do
    value
    |> Tuple.to_list()
    |> Enum.map(&wrap(&1, depth + 1))
    |> List.to_tuple()
  end

  defp wrap(value, depth) when is_map(value) do
    Map.new(value, fn {key, item} -> {wrap(key, depth + 1), wrap(item, depth + 1)} end)
  end

  defp wrap(value, _depth), do: local_value(value)

  defp unwrap(%LocalValue{value: value}), do: value
  defp unwrap(%_{} = value), do: value
  defp unwrap(value) when is_list(value), do: Enum.map(value, &unwrap/1)

  defp unwrap(value) when is_tuple(value) do
    value
    |> Tuple.to_list()
    |> Enum.map(&unwrap/1)
    |> List.to_tuple()
  end

  defp unwrap(value) when is_map(value) do
    Map.new(value, fn {key, item} -> {unwrap(key), unwrap(item)} end)
  end

  defp unwrap(value), do: value

  defp contains_local_value?(%LocalValue{}), do: true
  defp contains_local_value?(%_{}), do: false

  defp contains_local_value?(value) when is_list(value),
    do: Enum.any?(value, &contains_local_value?/1)

  defp contains_local_value?(value) when is_tuple(value) do
    value |> Tuple.to_list() |> Enum.any?(&contains_local_value?/1)
  end

  defp contains_local_value?(value) when is_map(value) do
    Enum.any?(value, fn {key, item} ->
      contains_local_value?(key) or contains_local_value?(item)
    end)
  end

  defp contains_local_value?(_value), do: false

  defp portable_struct?(value) do
    Runic.Identity.Projectable.impl_for(value) != Runic.Identity.Projectable.Any
  end

  defp local_value(value) do
    %LocalValue{
      value: value,
      digest: :crypto.hash(:sha256, :erlang.term_to_binary(value, [:deterministic]))
    }
  end
end
