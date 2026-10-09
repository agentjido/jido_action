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

  alias Jido.Exec.Fact.{LocalValue, PortableValue}
  alias Jido.Exec.Portable
  alias Runic.Identity
  alias Runic.Workflow.Fact

  @local_identity %{jido: %{identity_mode: :local}}
  @max_local_depth 32

  @doc false
  @spec local_root(term()) :: Fact.t()
  def local_root(value) do
    Fact.new(value: wrap(value, :local), meta: @local_identity)
  end

  @doc false
  @spec portable_root(term()) :: Fact.t()
  def portable_root(value) do
    validate_portable!(value, :input)
    Fact.new(value: wrap(value, :portable))
  end

  @doc false
  @spec child(Fact.t(), keyword()) :: Fact.t()
  def child(%Fact{} = parent, opts) do
    if local?(parent) do
      opts
      |> Keyword.update!(:value, &wrap(&1, :local))
      |> Keyword.update(:meta, @local_identity, &put_local_identity/1)
      |> Fact.new()
    else
      Fact.new(opts)
    end
  end

  @doc false
  @spec child(Fact.t(), keyword(), map()) :: Fact.t()
  def child(%Fact{} = parent, opts, runtime) do
    if Map.has_key?(runtime, :__jido_exec_durable__) do
      metadata = Keyword.get(opts, :meta, %{})

      {value, metadata} =
        encode_output(Keyword.fetch!(opts, :value), parent.value, metadata, runtime)

      opts |> Keyword.put(:value, value) |> Keyword.put(:meta, metadata) |> Fact.new()
    else
      child(parent, opts)
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
  def encode_output(value, input, metadata), do: encode_output(value, input, metadata, %{})

  @doc false
  @spec encode_output(term(), term(), map(), map()) :: {term(), map()}
  def encode_output(value, input, metadata, runtime) do
    case Map.fetch(runtime, :__jido_exec_durable__) do
      {:ok, true} ->
        validate_portable!(value, :output)
        validate_portable!(metadata, :metadata)
        {wrap(value, :portable), metadata}

      {:ok, false} ->
        {wrap(value, :local), put_local_identity(metadata)}

      :error ->
        if match?(%{jido: %{identity_mode: :local}}, metadata) or contains_local_value?(input),
          do: {wrap(value, :local), put_local_identity(metadata)},
          else: {value, metadata}
    end
  end

  defp local?(%Fact{meta: %{jido: %{identity_mode: :local}}}), do: true
  defp local?(%Fact{value: value}), do: contains_local_value?(value)

  defp put_local_identity(meta) do
    Map.update(meta, :jido, %{identity_mode: :local}, &Map.put(&1, :identity_mode, :local))
  end

  defp wrap(value, mode), do: wrap(value, mode, 0)

  defp wrap(value, _mode, _depth)
       when is_nil(value) or is_boolean(value) or is_integer(value) or is_float(value) or
              is_binary(value) or is_atom(value),
       do: value

  defp wrap(%Identity{} = value, _mode, _depth), do: value
  defp wrap(%LocalValue{value: value}, :portable, depth), do: wrap(value, :portable, depth)
  defp wrap(%PortableValue{value: value}, :portable, depth), do: wrap(value, :portable, depth)
  defp wrap(%LocalValue{} = value, :local, _depth), do: value
  defp wrap(%PortableValue{} = value, :local, _depth), do: value
  defp wrap(value, mode, depth) when depth >= @max_local_depth, do: encoded_value(value, mode)

  defp wrap(%_{} = value, mode, _depth) do
    if portable_struct?(value), do: value, else: encoded_value(value, mode)
  end

  defp wrap(value, mode, depth) when is_list(value) do
    if List.improper?(value),
      do: encoded_value(value, mode),
      else: Enum.map(value, &wrap(&1, mode, depth + 1))
  end

  defp wrap(value, mode, depth) when is_tuple(value) do
    value
    |> Tuple.to_list()
    |> Enum.map(&wrap(&1, mode, depth + 1))
    |> List.to_tuple()
  end

  defp wrap(value, mode, depth) when is_map(value) do
    Map.new(value, fn {key, item} -> {wrap(key, mode, depth + 1), wrap(item, mode, depth + 1)} end)
  end

  defp wrap(value, mode, _depth), do: encoded_value(value, mode)

  defp unwrap(%LocalValue{value: value}), do: value
  defp unwrap(%PortableValue{value: value}), do: value
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

  defp encoded_value(value, :local), do: local_value(value)

  defp encoded_value(value, :portable) do
    %PortableValue{value: value, digest: Identity.digest(:event_data, portable_document(value))}
  end

  defp portable_document(%module{} = value),
    do: {:struct, Atom.to_string(module), wrap(Map.from_struct(value), :portable)}

  defp portable_document(value) when is_list(value) do
    {heads, tail} = split_list(value, [])
    {:list, wrap(heads, :portable), wrap(tail, :portable)}
  end

  defp portable_document(value) when is_bitstring(value) do
    padding = rem(8 - rem(bit_size(value), 8), 8)
    {:bitstring, bit_size(value), <<value::bitstring, 0::size(padding)>>}
  end

  defp portable_document(value), do: {:value, wrap(value, :portable)}

  defp split_list([head | tail], heads), do: split_list(tail, [head | heads])
  defp split_list(tail, heads), do: {Enum.reverse(heads), tail}

  defp validate_portable!(value, field) do
    case Portable.validate(value, field) do
      :ok -> :ok
      {:error, error} -> raise error
    end
  end
end
