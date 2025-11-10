defmodule Jido.Action.Tool do
  @moduledoc """
  Provides functionality to convert Jido Execs into tool representations.

  This module allows Jido Execs to be easily integrated with AI systems
  like LangChain or Instructor by converting them into a standardized tool format.
  """

  @type tool :: %{
          name: String.t(),
          description: String.t(),
          function: (map(), map() -> {:ok, String.t()} | {:error, String.t()}),
          parameters_schema: map()
        }

  @doc """
  Converts a Jido Exec into a tool representation.

  ## Arguments

    * `action` - The module implementing the Jido.Action behavior.

  ## Returns

    A map representing the action as a tool, compatible with systems like LangChain.

  ## Examples

      iex> tool = Jido.Action.Tool.to_tool(MyExec)
      %{
        name: "my_action",
        description: "Performs a specific task",
        function: #Function<...>,
        parameters_schema: %{...}
      }
  """
  @spec to_tool(module()) :: tool()
  def to_tool(action) when is_atom(action) do
    %{
      name: action.name(),
      description: action.description(),
      function: &execute_action(action, &1, &2),
      parameters_schema: build_parameters_schema(action.schema())
    }
  end

  @doc """
  Executes an action and formats the result for tool output.

  This function is typically used as the function value in the tool representation.
  """
  @spec execute_action(module(), map(), map()) :: {:ok, String.t()} | {:error, String.t()}
  def execute_action(action, params, context) do
    # Convert string keys to atom keys and handle type conversion based on schema
    converted_params = convert_params_using_schema(params, action.schema())
    safe_context = context || %{}

    case Jido.Exec.run(action, converted_params, safe_context) do
      {:ok, result} ->
        {:ok, Jason.encode!(result)}

      {:error, %_{} = error} when is_exception(error) ->
        {:error, Jason.encode!(%{error: inspect(error)})}
    end
  end

  @doc """
  Helper function to convert params using schema information.

  Converts string keys to atom keys and handles type conversion based on schema.
  """
  def convert_params_using_schema(params, schema) do
    schema_keys = Jido.Action.Schema.known_keys(schema)

    Enum.reduce(schema_keys, %{}, fn key, acc ->
      string_key = to_string(key)

      if Map.has_key?(params, string_key) do
        value = params[string_key]

        # For NimbleOptions schemas, handle type conversion
        converted_value =
          if is_list(schema) do
            schema_entry = Keyword.get(schema, key, [])
            type = Keyword.get(schema_entry, :type)

            case {type, value} do
              {:float, val} when is_binary(val) ->
                case Float.parse(val) do
                  {num, _} -> num
                  :error -> val
                end

              {:integer, val} when is_binary(val) ->
                case Integer.parse(val) do
                  {num, _} -> num
                  :error -> val
                end

              _ ->
                value
            end
          else
            # For Zoi schemas, let the validation handle conversion
            value
          end

        Map.put(acc, key, converted_value)
      else
        acc
      end
    end)
  end

  @doc """
  Builds a parameters schema for the tool based on the action's schema.

  ## Arguments

    * `schema` - The NimbleOptions or Zoi schema from the action.

  ## Returns

    A map representing the parameters schema in a format compatible with LangChain.
  """
  @spec build_parameters_schema(Jido.Action.Schema.t()) :: map()
  def build_parameters_schema(schema) do
    Jido.Action.Schema.to_json_schema(schema)
  end
end
