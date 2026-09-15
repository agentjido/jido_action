defmodule Jido.Flow.Choice do
  @moduledoc """
  A named, ordered Choice with a required fallback Action.

      option =
        Jido.Flow.Choice.Option.new!(
          name: "ready",
          condition: Jido.Expr.new!(:eq, [Jido.Flow.Ref.input(:status), :ready]),
          action: MyApp.HandleReady
        )

      Jido.Flow.Choice.new!(
        name: "route",
        options: [option],
        fallback: Jido.Flow.Choice.Fallback.new!(action: MyApp.HandleOther)
      )
  """

  alias Jido.Flow.Error
  alias Jido.Flow.Component
  alias Jido.Flow.Expression

  @keys [:name, :options, :fallback, :needs, :meta]

  @schema Zoi.struct(
            __MODULE__,
            %{
              name: Zoi.string(description: "Component name"),
              options: Zoi.list(Zoi.any(), description: "Ordered Choice options"),
              fallback: Zoi.any(description: "Required Choice fallback"),
              needs:
                Zoi.list(Zoi.string(), description: "Explicit control dependencies")
                |> Zoi.default([]),
              meta: Zoi.map(description: "Portable author metadata") |> Zoi.default(%{})
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  defmodule Option do
    @moduledoc "One ordered Choice condition and Action."

    alias Jido.Flow.Error
    alias Jido.Flow.Component
    alias Jido.Flow.Expression

    @keys [:name, :condition, :action, :params]

    @schema Zoi.struct(
              __MODULE__,
              %{
                name: Zoi.string(description: "Choice option name"),
                condition: Zoi.any(description: "Choice condition"),
                action: Zoi.atom(description: "Choice Action module"),
                params: Zoi.any(description: "Choice Action parameters") |> Zoi.default(%{})
              },
              coerce: true
            )

    @type t :: unquote(Zoi.type_spec(@schema))

    @enforce_keys Zoi.Struct.enforce_keys(@schema)
    defstruct Zoi.Struct.struct_fields(@schema)

    @doc "Builds and validates one Choice option."
    @spec new(t() | map() | keyword()) :: {:ok, t()} | {:error, Exception.t()}
    def new(%__MODULE__{} = option), do: option |> Map.from_struct() |> new()

    def new(attrs) when is_list(attrs),
      do: if(Keyword.keyword?(attrs), do: new(Map.new(attrs)), else: invalid())

    def new(%{} = attrs) do
      with :ok <- known_keys(attrs),
           {:ok, name} <- Component.name(Map.get(attrs, :name)),
           {:ok, condition} <- condition(Map.get(attrs, :condition)),
           {:ok, action} <- Component.module(Map.get(attrs, :action), "choice option action"),
           {:ok, params} <- Expression.prepare(Map.get(attrs, :params, %{})) do
        {:ok, %__MODULE__{name: name, condition: condition, action: action, params: params}}
      end
    end

    def new(_attrs), do: invalid()

    @doc "Builds one Choice option or raises its validation error."
    @spec new!(t() | map() | keyword()) :: t() | no_return()
    def new!(attrs) do
      case new(attrs) do
        {:ok, option} -> option
        {:error, error} -> raise error
      end
    end

    defp condition(value)
         when is_struct(value, Jido.Expr) or is_struct(value, Jido.Flow.Ref) or is_boolean(value),
         do: Expression.condition(value, :flow)

    defp condition(_condition),
      do: {:error, Error.validation_error("choice option condition is required")}

    defp known_keys(attrs) do
      case Enum.reject(Map.keys(attrs), &(&1 in @keys)) do
        [] ->
          :ok

        [key | _rest] ->
          {:error, Error.validation_error("unknown choice option key: #{inspect(key)}")}
      end
    end

    defp invalid, do: {:error, Error.validation_error("choice option must be a map")}
  end

  defmodule Fallback do
    @moduledoc "The Action used when no Choice option matches."

    alias Jido.Flow.Error
    alias Jido.Flow.Component
    alias Jido.Flow.Expression

    @keys [:action, :params]

    @schema Zoi.struct(
              __MODULE__,
              %{
                action: Zoi.atom(description: "Fallback Action module"),
                params: Zoi.any(description: "Fallback Action parameters") |> Zoi.default(%{})
              },
              coerce: true
            )

    @type t :: unquote(Zoi.type_spec(@schema))

    @enforce_keys Zoi.Struct.enforce_keys(@schema)
    defstruct Zoi.Struct.struct_fields(@schema)

    @doc "Builds and validates one Choice fallback."
    @spec new(t() | map() | keyword()) :: {:ok, t()} | {:error, Exception.t()}
    def new(%__MODULE__{} = fallback), do: fallback |> Map.from_struct() |> new()

    def new(attrs) when is_list(attrs),
      do: if(Keyword.keyword?(attrs), do: new(Map.new(attrs)), else: invalid())

    def new(%{} = attrs) do
      with :ok <- known_keys(attrs),
           {:ok, action} <- Component.module(Map.get(attrs, :action), "choice fallback action"),
           {:ok, params} <- Expression.prepare(Map.get(attrs, :params, %{})) do
        {:ok, %__MODULE__{action: action, params: params}}
      end
    end

    def new(_attrs), do: invalid()

    @doc "Builds one Choice fallback or raises its validation error."
    @spec new!(t() | map() | keyword()) :: t() | no_return()
    def new!(attrs) do
      case new(attrs) do
        {:ok, fallback} -> fallback
        {:error, error} -> raise error
      end
    end

    defp known_keys(attrs) do
      case Enum.reject(Map.keys(attrs), &(&1 in @keys)) do
        [] ->
          :ok

        [key | _rest] ->
          {:error, Error.validation_error("unknown choice fallback key: #{inspect(key)}")}
      end
    end

    defp invalid, do: {:error, Error.validation_error("choice fallback must be a map")}
  end

  @doc "Builds and validates one canonical Choice."
  @spec new(t() | map() | keyword()) :: {:ok, t()} | {:error, Exception.t()}
  def new(%__MODULE__{} = choice), do: choice |> Map.from_struct() |> new()

  def new(attrs) when is_list(attrs),
    do: if(Keyword.keyword?(attrs), do: new(Map.new(attrs)), else: invalid())

  def new(%{} = attrs) do
    with :ok <- known_keys(attrs),
         {:ok, name} <- Component.name(Map.get(attrs, :name)),
         {:ok, options} <- options(Map.get(attrs, :options)),
         {:ok, fallback} <- fallback(Map.get(attrs, :fallback)),
         {:ok, needs_names} <- Component.needs_names(Map.get(attrs, :needs, [])),
         {:ok, meta} <- Component.meta(Map.get(attrs, :meta, %{})) do
      {:ok,
       %__MODULE__{
         name: name,
         options: options,
         fallback: fallback,
         needs: needs_names,
         meta: meta
       }}
    end
  end

  def new(_attrs), do: invalid()

  @doc "Builds one canonical Choice or raises its validation error."
  @spec new!(t() | map() | keyword()) :: t() | no_return()
  def new!(attrs) do
    case new(attrs) do
      {:ok, choice} -> choice
      {:error, error} -> raise error
    end
  end

  @doc false
  @spec result_deps(t()) :: [String.t()]
  def result_deps(%__MODULE__{} = choice) do
    choice.options
    |> Enum.flat_map(fn option ->
      Expression.result_refs(option.condition) ++ Expression.result_refs(option.params)
    end)
    |> Kernel.++(Expression.result_refs(choice.fallback.params))
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc false
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = choice) do
    %{
      kind: :choice,
      name: choice.name,
      options:
        Enum.map(choice.options, fn option ->
          %{
            name: option.name,
            condition: Expression.to_map(option.condition),
            action: option.action,
            params: Expression.to_map(option.params)
          }
        end),
      fallback: %{
        action: choice.fallback.action,
        params: Expression.to_map(choice.fallback.params)
      },
      needs: choice.needs,
      meta: choice.meta
    }
  end

  defp options(values) when is_list(values) do
    cond do
      values == [] ->
        {:error, Error.validation_error("choice must contain at least one option")}

      List.improper?(values) ->
        {:error, Error.validation_error("choice options must be a proper list")}

      true ->
        values
        |> Enum.with_index()
        |> Enum.reduce_while({:ok, []}, fn {value, index}, {:ok, options} ->
          case Option.new(value) do
            {:ok, option} -> {:cont, {:ok, [option | options]}}
            {:error, error} -> {:halt, {:error, Error.prefix_path(error, [:options, index])}}
          end
        end)
        |> reverse_options()
    end
  end

  defp options(_values), do: {:error, Error.validation_error("choice options must be a list")}

  defp reverse_options({:ok, options}) do
    options = Enum.reverse(options)

    case duplicate_name(options) do
      nil ->
        {:ok, options}

      name ->
        {:error, Error.validation_error("choice option names must be unique", %{name: name})}
    end
  end

  defp reverse_options(error), do: error

  defp fallback(nil), do: {:error, Error.validation_error("choice fallback is required")}
  defp fallback(value), do: Fallback.new(value)

  defp duplicate_name(options) do
    names = Enum.map(options, & &1.name)

    case names -- Enum.uniq(names) do
      [] -> nil
      [name | _] -> name
    end
  end

  defp known_keys(attrs) do
    case Enum.reject(Map.keys(attrs), &(&1 in @keys)) do
      [] -> :ok
      [key | _rest] -> {:error, Error.validation_error("unknown choice key: #{inspect(key)}")}
    end
  end

  defp invalid, do: {:error, Error.validation_error("choice configuration must be a map")}
end
