defmodule Jido.Instruction do
  @moduledoc """
  A small call frame describing one requested action execution.

  `Jido.Instruction` captures intent to run an action with params and context.
  It does not represent a workflow, graph, program, source artifact, or
  execution policy. Construction validates the invocation shape; Flow runtime
  paths can explicitly validate the action callback contract before execution.

      %Jido.Instruction{
        action: MyApp.Actions.SendEmail,
        params: %{to: "user@example.com"},
        context: %{tenant_id: "tenant_123"}
      }

  Instructions are consumed by `Jido.Flow.Step` as action leaf call frames.
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
  @spec normalize!(module() | t(), map() | keyword(), map() | keyword()) :: t()
  def normalize!(action_or_instruction, params \\ %{}, context \\ %{}) do
    params = normalize_map!(params, :params)
    context = normalize_map!(context, :context)
    build_instruction!(action_or_instruction, params, context)
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
    action
    |> Module.split()
    |> List.last()
    |> Macro.underscore()
    |> String.to_atom()
  end

  @doc false
  @spec normalize_map!(term(), atom()) :: map()
  def normalize_map!(nil, _field), do: %{}
  def normalize_map!(value, _field) when is_map(value), do: value

  def normalize_map!(value, _field) when is_list(value) do
    if Keyword.keyword?(value) do
      Map.new(value)
    else
      raise ArgumentError, "expected a map or keyword list, got: #{inspect(value)}"
    end
  end

  def normalize_map!(value, field) do
    raise ArgumentError, "expected #{field} to be a map or keyword list, got: #{inspect(value)}"
  end

  @doc """
  Creates an instruction from a map or keyword list.

  `:action` is required. `:params` and `:context` are optional.
  Params and context may be maps or keyword lists.
  """
  @spec new(map() | keyword()) ::
          {:ok, t()} | {:error, :missing_action | :invalid_action | Exception.t()}
  def new(attrs) when is_list(attrs), do: attrs |> Map.new() |> new()

  def new(%{} = attrs) do
    with :ok <- validate_action_present(attrs),
         :ok <- validate_action_is_atom(attrs),
         {:ok, normalized_attrs} <- normalize_attrs(attrs) do
      {:ok,
       %__MODULE__{
         action: normalized_attrs.action,
         params: normalized_attrs.params,
         context: normalized_attrs.context
       }}
    end
  end

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

  defp build_instruction!(%__MODULE__{} = instruction, params, context) do
    new!(%{
      action: instruction.action,
      params: Map.merge(normalize_map!(instruction.params || %{}, :params), params),
      context: Map.merge(normalize_map!(instruction.context || %{}, :context), context)
    })
  end

  defp build_instruction!(action, params, context)
       when is_atom(action) and not is_nil(action) do
    new!(%{
      action: action,
      params: params,
      context: context
    })
  end

  defp build_instruction!(other, _params, _context) do
    raise ArgumentError,
          "expected an action module or %Jido.Instruction{}, got: #{inspect(other)}"
  end

  defp invalid_action_contract(action, reason) do
    {:error,
     Error.validation_error("module is not a valid Jido action", %{
       action: action,
       reason: reason
     })}
  end

  defp validate_action_present(attrs) do
    if Map.has_key?(attrs, :action), do: :ok, else: {:error, :missing_action}
  end

  defp validate_action_is_atom(%{action: action}) when is_atom(action) and not is_nil(action),
    do: :ok

  defp validate_action_is_atom(_attrs), do: {:error, :invalid_action}

  defp normalize_attrs(attrs) do
    with {:ok, params} <- normalize_params(Map.get(attrs, :params, %{})),
         {:ok, context} <- normalize_context(Map.get(attrs, :context, %{})) do
      {:ok,
       attrs
       |> Map.put(:params, params)
       |> Map.put(:context, context)}
    end
  end

  defp normalize_params(nil), do: {:ok, %{}}
  defp normalize_params(params) when is_map(params), do: {:ok, params}

  defp normalize_params(params) when is_list(params) do
    if Keyword.keyword?(params) do
      {:ok, Map.new(params)}
    else
      {:error,
       Error.execution_error("Invalid params format. Params must be a map or keyword list.", %{
         params: params,
         expected_format: "%{key: value} or [key: value]"
       })}
    end
  end

  defp normalize_params(invalid) do
    {:error,
     Error.execution_error("Invalid params format. Params must be a map or keyword list.", %{
       params: invalid,
       expected_format: "%{key: value} or [key: value]"
     })}
  end

  defp normalize_context(nil), do: {:ok, %{}}
  defp normalize_context(context) when is_map(context), do: {:ok, context}

  defp normalize_context(context) when is_list(context) do
    if Keyword.keyword?(context) do
      {:ok, Map.new(context)}
    else
      {:error,
       Error.execution_error("Invalid context format. Context must be a map or keyword list.", %{
         context: context,
         expected_format: "%{key: value} or [key: value]"
       })}
    end
  end

  defp normalize_context(invalid) do
    {:error,
     Error.execution_error("Invalid context format. Context must be a map or keyword list.", %{
       context: invalid,
       expected_format: "%{key: value} or [key: value]"
     })}
  end
end
