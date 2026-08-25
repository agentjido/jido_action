defmodule Jido.Flow.Step do
  @moduledoc "A named Jido Action call in a canonical Flow."

  alias Jido.Flow.Error
  alias Jido.Flow.Component
  alias Jido.Flow.Expression

  @schema Zoi.struct(
            __MODULE__,
            %{
              name: Zoi.string(description: "Component name"),
              action: Zoi.atom(description: "Jido Action module"),
              params: Zoi.any(description: "Action parameter expression") |> Zoi.default(%{}),
              after:
                Zoi.list(Zoi.string(), description: "Explicit control order") |> Zoi.default([]),
              meta: Zoi.map(description: "Portable author metadata") |> Zoi.default(%{})
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Builds and validates one canonical Step."
  @spec new(map() | keyword() | t()) :: {:ok, t()} | {:error, Exception.t()}
  def new(%__MODULE__{} = step), do: step |> Map.from_struct() |> new()

  def new(attrs) when is_list(attrs) do
    if Keyword.keyword?(attrs),
      do: attrs |> Map.new() |> new(),
      else: {:error, Error.validation_error("step configuration must be a map")}
  end

  def new(%{} = attrs) do
    with :ok <- known_keys(attrs),
         {:ok, name} <- Component.name(Map.get(attrs, :name)),
         {:ok, action} <- Component.module(Map.get(attrs, :action), "step action"),
         {:ok, params} <- expression(Map.get(attrs, :params, %{})),
         {:ok, after_names} <- Component.after_names(Map.get(attrs, :after, [])),
         {:ok, meta} <- Component.meta(Map.get(attrs, :meta, %{})) do
      {:ok,
       %__MODULE__{name: name, action: action, params: params, after: after_names, meta: meta}}
    end
  end

  def new(_attrs), do: {:error, Error.validation_error("step configuration must be a map")}

  @doc "Builds one canonical Step or raises its validation error."
  @spec new!(map() | keyword() | t()) :: t() | no_return()
  def new!(attrs) do
    case new(attrs) do
      {:ok, step} -> step
      {:error, error} -> raise error
    end
  end

  @doc false
  def result_refs(%__MODULE__{params: params}), do: Expression.result_refs(params)

  defp expression(value) do
    with {:ok, value} <- Expression.normalize(value),
         :ok <- Expression.validate(value) do
      {:ok, value}
    end
  end

  defp known_keys(attrs) do
    case Enum.find(Map.keys(attrs), &(&1 not in [:name, :action, :params, :after, :meta])) do
      nil -> :ok
      key -> {:error, Error.validation_error("unknown step configuration key: #{inspect(key)}")}
    end
  end
end
