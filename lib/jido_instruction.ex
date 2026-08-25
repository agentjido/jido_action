defmodule Jido.Instruction do
  @moduledoc """
  Defines the invocation value for one executable target.

  An Instruction contains a target, params, context, and metadata. The target
  follows the `Jido.Executable` contract. It can contain an Action module, a
  Flow module, or a runtime `Jido.Flow` value.

      %Jido.Instruction{
        target: MyApp.Actions.SendEmail,
        params: %{to: "user@example.com"},
        context: %{tenant_id: "tenant_123"},
        metadata: %{request_id: "req_123"}
      }

  The constructor resolves the target and validates the three invocation maps.
  It keeps the target value without conversion. Metadata has no execution
  meaning in this module.

  Constructor maps are not a stored or JSON representation. Executable module
  atoms and runtime Flow values do not have one general JSON form.
  """

  alias Jido.Action.Error
  alias Jido.Executable

  @schema Zoi.struct(
            __MODULE__,
            %{
              target: Zoi.any(description: "Executable target"),
              params: Zoi.map(description: "Executable parameters") |> Zoi.default(%{}),
              context: Zoi.map(description: "Execution context") |> Zoi.default(%{}),
              metadata: Zoi.map(description: "Invocation metadata") |> Zoi.default(%{})
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))
  @type executable_target :: Executable.target()
  @type params :: map()
  @type context :: map()
  @type metadata :: map()

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc false
  @spec normalize!(executable_target() | t(), map() | keyword(), map() | keyword()) :: t()
  def normalize!(target_or_instruction, params \\ %{}, context \\ %{}) do
    params = normalize_map!(params, :params)
    context = normalize_map!(context, :context)

    case target_or_instruction do
      %__MODULE__{} = instruction ->
        normalize_instruction!(instruction, params, context)

      target ->
        new!(%{target: target, params: params, context: context})
    end
  end

  defp normalize_instruction!(instruction, params, context) do
    normalized = merge_instruction!(instruction, params, context)

    case new(Map.from_struct(normalized)) do
      {:ok, normalized} ->
        normalized

      {:error, error} ->
        raise Error.validation_error("Invalid instruction configuration", %{reason: error})
    end
  end

  @doc false
  @spec normalize_resolved!(executable_target() | t(), map() | keyword(), map() | keyword()) ::
          t()
  def normalize_resolved!(target_or_instruction, params, context) do
    params = normalize_map!(params, :params)
    context = normalize_map!(context, :context)

    case target_or_instruction do
      %__MODULE__{} = instruction -> merge_instruction!(instruction, params, context)
      target -> %__MODULE__{target: target, params: params, context: context, metadata: %{}}
    end
  end

  defp merge_instruction!(instruction, params, context) do
    %__MODULE__{
      target: instruction.target,
      params: Map.merge(normalize_map!(instruction.params || %{}, :params), params),
      context: Map.merge(normalize_map!(instruction.context || %{}, :context), context),
      metadata: normalize_map!(instruction.metadata || %{}, :metadata)
    }
  end

  @spec normalize_map!(term(), atom()) :: map()
  defp normalize_map!(value, field) do
    case normalize_map_field(value, field) do
      {:ok, map} ->
        map

      {:error, _error} ->
        raise ArgumentError, normalize_map_message(value, field)
    end
  end

  @doc """
  Creates an instruction from a map or keyword list.

  `:target` is the executable target and is required. `:params`, `:context`,
  and `:metadata` are optional. The three invocation fields can be maps or
  keyword lists.
  """
  @spec new(map() | keyword()) :: {:ok, t()} | {:error, Exception.t()}
  def new(attrs) when is_list(attrs) do
    if Keyword.keyword?(attrs) do
      attrs |> Map.new() |> new()
    else
      {:error,
       Error.validation_error("Invalid instruction configuration", %{
         reason: :invalid_attributes
       })}
    end
  end

  def new(%{target: target} = attrs) do
    with {:ok, _executable} <- Executable.resolve(target),
         {:ok, params} <- normalize_map_field(Map.get(attrs, :params, %{}), :params),
         {:ok, context} <- normalize_map_field(Map.get(attrs, :context, %{}), :context),
         {:ok, metadata} <- normalize_map_field(Map.get(attrs, :metadata, %{}), :metadata) do
      {:ok,
       %__MODULE__{
         target: target,
         params: params,
         context: context,
         metadata: metadata
       }}
    end
  end

  def new(%{}) do
    {:error,
     Error.validation_error("Invalid instruction configuration", %{
       field: :target,
       reason: :missing
     })}
  end

  def new(_attrs) do
    {:error,
     Error.validation_error("Invalid instruction configuration", %{
       reason: :invalid_attributes
     })}
  end

  @doc """
  Creates an instruction or raises on failure.
  """
  @spec new!(map() | keyword()) :: t() | no_return()
  def new!(attrs) do
    case new(attrs) do
      {:ok, instruction} ->
        instruction

      {:error, error} when is_exception(error) ->
        raise error

      {:error, error} ->
        raise Error.validation_error("Invalid instruction configuration", %{reason: error})
    end
  end

  defp normalize_map_field(nil, _field), do: {:ok, %{}}
  defp normalize_map_field(value, _field) when is_map(value), do: {:ok, value}

  defp normalize_map_field(value, field) when is_list(value) do
    if Keyword.keyword?(value) do
      {:ok, Map.new(value)}
    else
      invalid_map_field(field, value)
    end
  end

  defp normalize_map_field(value, field), do: invalid_map_field(field, value)

  defp invalid_map_field(field, value) do
    label = Atom.to_string(field)

    {:error,
     Error.validation_error(
       "Invalid #{label} format. #{String.capitalize(label)} must be a map or keyword list.",
       %{
         field => value,
         expected_format: "%{key: value} or [key: value]"
       }
     )}
  end

  defp normalize_map_message(value, _field) when is_list(value),
    do: "expected a map or keyword list, got: #{inspect(value)}"

  defp normalize_map_message(value, field),
    do: "expected #{field} to be a map or keyword list, got: #{inspect(value)}"
end
