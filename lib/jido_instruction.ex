defmodule Jido.Instruction do
  @moduledoc """
  A small call frame describing one requested action execution.

  `Jido.Instruction` captures intent to run an action with params, context, and
  execution options. It does not represent a workflow, graph, program, source
  artifact, or verified action contract.

      %Jido.Instruction{
        action: MyApp.Actions.SendEmail,
        params: %{to: "user@example.com"},
        context: %{tenant_id: "tenant_123"},
        opts: [timeout: 5_000]
      }

  Use `Jido.Exec.run/1` or `Jido.Exec.run/4` to execute an instruction.
  """

  alias Jido.Action.Error
  alias Jido.Action.ID
  alias Jido.Instruction

  @schema Zoi.struct(
            __MODULE__,
            %{
              id:
                Zoi.string(description: "Unique instruction identifier")
                |> Zoi.optional(),
              action:
                Zoi.atom(description: "Action module to execute")
                |> Zoi.refine({__MODULE__, :validate_action_module, []}),
              params: Zoi.map(description: "Parameters for the action") |> Zoi.default(%{}),
              context: Zoi.map(description: "Execution context") |> Zoi.default(%{}),
              opts:
                Zoi.keyword(Zoi.any(), description: "Runtime execution options")
                |> Zoi.default([])
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))
  @type action_module :: module()
  @type action_params :: map()
  @type action_context :: map()
  @type action_opts :: keyword()

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc false
  @spec validate_action_module(term(), keyword()) :: :ok | {:error, String.t()}
  def validate_action_module(value, _opts \\ [])
  def validate_action_module(value, _opts) when is_atom(value) and not is_nil(value), do: :ok
  def validate_action_module(value, _opts) when is_atom(value), do: {:error, "cannot be nil"}
  def validate_action_module(_value, _opts), do: {:error, "must be an atom"}

  @doc """
  Creates an instruction from a map or keyword list.

  `:action` is required. `:id`, `:params`, `:context`, and `:opts` are optional.
  Params and context may be maps or keyword lists; opts must be a keyword list.
  """
  @spec new(map() | keyword()) ::
          {:ok, t()} | {:error, :missing_action | :invalid_action | Exception.t()}
  def new(attrs) when is_list(attrs), do: attrs |> Map.new() |> new()

  def new(%{} = attrs) do
    with :ok <- validate_action_present(attrs),
         :ok <- validate_action_is_atom(attrs),
         {:ok, normalized_attrs} <- normalize_attrs(attrs) do
      normalized_attrs
      |> apply_defaults()
      |> parse_with_zoi()
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

  @doc """
  Validates that all instructions reference allowed action modules.
  """
  @spec validate_allowed_actions(t() | [t()], [module()]) :: :ok | {:error, Exception.t()}
  def validate_allowed_actions(%Instruction{} = instruction, allowed_actions) do
    validate_allowed_actions([instruction], allowed_actions)
  end

  def validate_allowed_actions(instructions, allowed_actions) when is_list(instructions) do
    disallowed =
      instructions
      |> Enum.map(& &1.action)
      |> Enum.reject(&(&1 in allowed_actions))

    if Enum.empty?(disallowed) do
      :ok
    else
      {:error,
       Error.config_error(
         "Actions not allowed: #{Enum.map_join(disallowed, ", ", &inspect/1)}",
         %{
           actions: disallowed,
           allowed_actions: allowed_actions
         }
       )}
    end
  end

  defp validate_action_present(attrs) do
    if Map.has_key?(attrs, :action), do: :ok, else: {:error, :missing_action}
  end

  defp validate_action_is_atom(%{action: action}) when is_atom(action) and not is_nil(action),
    do: :ok

  defp validate_action_is_atom(_attrs), do: {:error, :invalid_action}

  defp normalize_attrs(attrs) do
    with {:ok, params} <- normalize_params(Map.get(attrs, :params, %{})),
         {:ok, context} <- normalize_context(Map.get(attrs, :context, %{})),
         {:ok, opts} <- normalize_opts(Map.get(attrs, :opts, [])) do
      {:ok,
       attrs
       |> Map.put(:params, params)
       |> Map.put(:context, context)
       |> Map.put(:opts, opts)}
    end
  end

  defp apply_defaults(attrs) do
    attrs
    |> Map.update(:id, ID.uuid7(), fn
      nil -> ID.uuid7()
      id -> id
    end)
    |> Map.put_new_lazy(:id, &ID.uuid7/0)
    |> Map.put_new(:params, %{})
    |> Map.put_new(:context, %{})
    |> Map.put_new(:opts, [])
  end

  defp parse_with_zoi(attrs) do
    case Zoi.parse(@schema, attrs) do
      {:ok, instruction} ->
        {:ok, instruction}

      {:error, errors} ->
        {:error,
         Error.validation_error("Invalid instruction configuration", %{
           errors: format_zoi_errors(errors)
         })}
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

  defp normalize_opts(nil), do: {:ok, []}

  defp normalize_opts(opts) when is_list(opts) do
    if Keyword.keyword?(opts) do
      {:ok, opts}
    else
      {:error,
       Error.execution_error("Invalid opts format. Opts must be a keyword list.", %{opts: opts})}
    end
  end

  defp normalize_opts(invalid) do
    {:error,
     Error.execution_error("Invalid opts format. Opts must be a keyword list.", %{opts: invalid})}
  end

  defp format_zoi_errors(errors) when is_list(errors) do
    Enum.map(errors, fn
      %{path: path, message: message} = error ->
        %{
          path: path,
          message: message,
          code: Map.get(error, :code)
        }

      error ->
        %{message: inspect(error)}
    end)
  end
end
