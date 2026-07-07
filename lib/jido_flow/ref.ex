defmodule Jido.Flow.Ref do
  @moduledoc """
  References used by the canonical Flow IR.

  Refs are data only. They identify values from the Flow input, runtime context,
  literal values, or results produced by named Flow nodes.
  """

  @type kind :: :input | :context | :result | :value
  @type node_name :: String.t()
  @type path :: [atom() | String.t() | integer()]

  @schema Zoi.struct(
            __MODULE__,
            %{
              type: Zoi.enum([:input, :context, :result, :value], description: "Reference type"),
              node: Zoi.string(description: "Result node name") |> Zoi.optional(),
              path: Zoi.list(Zoi.any(), description: "Nested value path") |> Zoi.default([]),
              value: Zoi.any(description: "Literal value") |> Zoi.optional()
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc """
  Builds a reference to a value in the Flow input.
  """
  @spec input(atom() | String.t() | integer() | list()) :: t()
  def input(path), do: %__MODULE__{type: :input, path: normalize_path(path)}

  @doc """
  Builds a reference to a value in the runtime Flow context.
  """
  @spec context(atom() | String.t() | integer() | list() | nil) :: t()
  def context(path), do: %__MODULE__{type: :context, path: normalize_path(path)}

  @doc """
  Builds a reference to a named node result.
  """
  @spec result(atom() | String.t(), atom() | String.t() | integer() | list()) :: t()
  def result(node, path \\ []) do
    %__MODULE__{type: :result, node: normalize_node_name(node), path: normalize_path(path)}
  end

  @doc """
  Wraps a literal value as a Flow expression.
  """
  @spec value(term()) :: t()
  def value(value), do: %__MODULE__{type: :value, value: value}

  @doc false
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{type: :input, path: path}), do: %{type: :input, path: path}

  def to_map(%__MODULE__{type: :context, path: path}), do: %{type: :context, path: path}

  def to_map(%__MODULE__{type: :result, node: node, path: path}) do
    %{type: :result, node: node, path: path}
  end

  def to_map(%__MODULE__{type: :value, value: value}), do: %{type: :value, value: value}

  @doc false
  @spec normalize_path(atom() | String.t() | integer() | list() | nil) :: path()
  def normalize_path(nil), do: []
  def normalize_path(path) when is_list(path), do: path
  def normalize_path(path), do: [path]

  defp normalize_node_name(node) when is_atom(node) and not is_nil(node), do: Atom.to_string(node)
  defp normalize_node_name(node) when is_binary(node), do: node
end
