defmodule Jido.Flow.Parser do
  @moduledoc """
  Trusted developer parser for the first Flow source subset.

  The parser uses `Code.string_to_quoted/2` only to obtain Elixir AST. It does
  not evaluate or compile the provided source.
  """

  alias Jido.Action.Error
  alias Jido.Flow
  alias Jido.Flow.Syntax
  alias Jido.Flow.Syntax.Lowerer

  @parser_option_keys [:profile, :actions]

  @doc """
  Parses trusted Flow source into a canonical `%Jido.Flow{}`.
  """
  @spec parse(String.t(), map() | keyword()) :: {:ok, Flow.t()} | {:error, Exception.t()}
  def parse(source, opts \\ [])

  def parse(source, opts) when is_binary(source) do
    with {:ok, parser_config, flow_opts} <- options(opts),
         {:ok, quoted} <- quoted(source, parser_config),
         {:ok, operations} <- operations_from_quoted(quoted, parser_config),
         {:ok, config} <- config(flow_opts) do
      config
      |> Syntax.new()
      |> Map.put(:operations, operations)
      |> Lowerer.lower()
    end
  end

  def parse(_source, _opts), do: {:error, Error.validation_error("flow source must be a string")}

  defp options(opts) when is_list(opts) do
    if Keyword.keyword?(opts) do
      opts
      |> Map.new()
      |> options()
    else
      {:error, Error.validation_error("flow parser options must be a map or keyword list")}
    end
  end

  defp options(%{} = opts) do
    parser_opts = Map.take(opts, @parser_option_keys)
    flow_opts = Map.drop(opts, @parser_option_keys)

    with {:ok, parser_config} <- parser_config(parser_opts) do
      {:ok, parser_config, flow_opts}
    end
  end

  defp options(_opts) do
    {:error, Error.validation_error("flow parser options must be a map or keyword list")}
  end

  defp parser_config(opts) do
    with {:ok, profile} <- profile(Map.get(opts, :profile, :trusted)),
         {:ok, actions} <- actions(Map.get(opts, :actions, %{})) do
      {:ok, %{profile: profile, actions: actions}}
    end
  end

  defp profile(profile) when profile in [:trusted, :stored], do: {:ok, profile}

  defp profile(profile) do
    {:error,
     Error.validation_error("unsupported flow parser profile: #{inspect(profile)}", %{
       profile: profile
     })}
  end

  defp actions(actions) when is_list(actions) do
    if Keyword.keyword?(actions) do
      actions
      |> Map.new()
      |> actions()
    else
      action_registry_error(actions)
    end
  end

  defp actions(%{} = actions) do
    Enum.reduce_while(actions, {:ok, %{}}, fn
      {identifier, action}, {:ok, acc}
      when (is_binary(identifier) or (is_atom(identifier) and not is_nil(identifier))) and
             is_atom(action) and not is_nil(action) ->
        {:cont, {:ok, Map.put(acc, identifier, action)}}

      {_identifier, _action}, {:ok, _acc} ->
        {:halt, action_registry_error(actions)}
    end)
  end

  defp actions(actions), do: action_registry_error(actions)

  defp action_registry_error(actions) do
    {:error,
     Error.validation_error(
       "flow action registry must map string or atom identifiers to modules",
       %{
         actions: actions
       }
     )}
  end

  defp quoted(source, parser_config) do
    case Code.string_to_quoted(source, quoted_options(parser_config)) do
      {:ok, quoted} ->
        {:ok, quoted}

      {:error, {line, error, token}} ->
        {:error,
         Error.validation_error("invalid flow source: #{format_parse_error(error, token)}", %{
           line: line
         })}
    end
  end

  defp quoted_options(%{profile: :trusted}), do: [columns: true, token_metadata: true]

  defp quoted_options(%{profile: :stored}) do
    [columns: true, token_metadata: true, existing_atoms_only: true]
  end

  defp operations_from_quoted({:flow, _meta, [[do: block]]}, parser_config) do
    {:ok, Jido.Flow.DSL.__parse_block__(block, __ENV__, parser_config)}
  rescue
    error in CompileError ->
      {:error, compile_error(error)}
  end

  defp operations_from_quoted(quoted, _parser_config) do
    {:error,
     Error.validation_error("flow source must contain a single flow do block", %{
       form: Macro.to_string(quoted)
     })}
  end

  defp config(%{} = opts), do: Flow.__validate_config__(opts)

  defp compile_error(%CompileError{} = error) do
    Error.validation_error(error.description, %{
      file: error.file,
      line: error.line
    })
  end

  defp format_parse_error(error, token) do
    message = if is_binary(error), do: error, else: inspect(error)
    "#{message} #{inspect(token)}"
  end
end
