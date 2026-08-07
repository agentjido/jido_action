defmodule Jido.Instruction do
  @moduledoc """
  A small call frame describing one requested action execution.

  `Jido.Instruction` captures intent to run an action with params and context.
  It does not represent a workflow, graph, program, source artifact, or
  execution policy. Construction validates the invocation shape; callers can
  explicitly validate the action callback contract before execution.

      %Jido.Instruction{
        action: MyApp.Actions.SendEmail,
        params: %{to: "user@example.com"},
        context: %{tenant_id: "tenant_123"}
      }

  Instructions are plain data for one action invocation.
  """

  alias Jido.Action.Error

  @schema Zoi.struct(
            __MODULE__,
            %{
              action:
                Zoi.atom(description: "Action module to execute")
                |> Zoi.refine({__MODULE__, :validate_action_module, []}),
              params: Zoi.map(description: "Parameters for the action") |> Zoi.default(%{}),
              context: Zoi.map(description: "Execution context") |> Zoi.default(%{})
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))
  @type action_module :: module()
  @type action_params :: map()
  @type action_context :: map()

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc false
  @spec validate_action_module(term(), keyword()) :: :ok | {:error, String.t()}
  def validate_action_module(value, _opts \\ [])
  def validate_action_module(value, _opts) when is_atom(value) and not is_nil(value), do: :ok
  def validate_action_module(value, _opts) when is_atom(value), do: {:error, "cannot be nil"}
  def validate_action_module(_value, _opts), do: {:error, "must be an atom"}

  @doc false
  @spec normalize!(term(), map() | keyword(), map() | keyword()) :: t()
  def normalize!(action_or_instruction, params \\ %{}, context \\ %{}) do
    params = normalize_map!(params, :params)
    context = normalize_map!(context, :context)

    cond do
      is_struct(action_or_instruction, __MODULE__) ->
        instruction = action_or_instruction

        new!(%{
          action: instruction.action,
          params: Map.merge(normalize_map!(instruction.params || %{}, :params), params),
          context: Map.merge(normalize_map!(instruction.context || %{}, :context), context)
        })

      is_atom(action_or_instruction) and not is_nil(action_or_instruction) ->
        new!(%{action: action_or_instruction, params: params, context: context})

      true ->
        raise ArgumentError,
              "expected an action module or %Jido.Instruction{}, got: #{inspect(action_or_instruction)}"
    end
  end

  @doc false
  @spec validate_action_contract(term()) :: :ok | {:error, Exception.t()}
  def validate_action_contract(action) when is_atom(action) and not is_nil(action) do
    case Code.ensure_loaded(action) do
      {:module, _module} ->
        cond do
          not function_exported?(action, :run, 2) ->
            invalid_action_contract(action, "missing run/2")

          not function_exported?(action, :validate_params, 1) ->
            invalid_action_contract(action, "missing validate_params/1")

          not function_exported?(action, :validate_output, 1) ->
            invalid_action_contract(action, "missing validate_output/1")

          true ->
            :ok
        end

      {:error, reason} ->
        {:error,
         Error.validation_error("action module could not be loaded", %{
           action: action,
           reason: reason
         })}
    end
  end

  def validate_action_contract(action) do
    {:error, Error.validation_error("expected an action module, got: #{inspect(action)}")}
  end

  @doc false
  @spec derive_action_name(module()) :: atom()
  def derive_action_name(action) do
    derived_name =
      action
      |> Module.split()
      |> List.last()
      |> Macro.underscore()

    String.to_existing_atom(derived_name)
  rescue
    ArgumentError ->
      raise ArgumentError,
            "could not derive action name without creating a new atom from #{inspect(action)}; pass an explicit atom name"
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

  `:action` is required. `:params` and `:context` are optional.
  Params and context may be maps or keyword lists.
  """
  @spec new(map() | keyword()) ::
          {:ok, t()} | {:error, :missing_action | :invalid_action | Exception.t()}
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

  def new(%{action: action} = attrs) when is_atom(action) and not is_nil(action) do
    with {:ok, params} <- normalize_map_field(Map.get(attrs, :params, %{}), :params),
         {:ok, context} <- normalize_map_field(Map.get(attrs, :context, %{}), :context) do
      {:ok,
       %__MODULE__{
         action: action,
         params: params,
         context: context
       }}
    end
  end

  def new(%{action: _action}), do: {:error, :invalid_action}
  def new(%{}), do: {:error, :missing_action}
  def new(_attrs), do: {:error, :missing_action}

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

      {:error, reason} ->
        raise Error.validation_error("Invalid instruction configuration", %{reason: reason})
    end
  end

  @doc false
  @spec validate_action_contract!(term()) :: :ok | no_return()
  def validate_action_contract!(action) do
    with :ok <- validate_action_contract(action) do
      :ok
    else
      {:error, error} ->
        raise ArgumentError, Exception.message(error)
    end
  end

  defp invalid_action_contract(action, reason) do
    {:error,
     Error.validation_error("module is not a valid Jido action", %{
       action: action,
       reason: reason
     })}
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
     Error.execution_error(
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
