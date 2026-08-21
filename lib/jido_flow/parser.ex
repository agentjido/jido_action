defmodule Jido.Flow.Parser do
  @moduledoc """
  Trusted developer parser for the first Flow source subset.

  The parser uses `Code.string_to_quoted/2` only to obtain Elixir AST. It does
  not evaluate or compile the provided source.
  """

  alias Jido.Action
  alias Jido.Action.Error
  alias Jido.Flow
  alias Jido.Flow.ActionRegistry
  alias Jido.Flow.ContractBundle
  alias Jido.Flow.ResourceBudget
  alias Jido.Flow.Syntax
  alias Jido.Flow.Syntax.Lowerer

  @parser_option_keys [:profile, :actions, :state_schemas]

  @doc """
  Parses trusted Flow source into a canonical `%Jido.Flow{}`.
  """
  @spec parse(String.t(), map() | keyword()) :: {:ok, Flow.t()} | {:error, Exception.t()}
  def parse(source, opts \\ [])

  def parse(source, opts) when is_binary(source) do
    with {:ok, parser_config, flow_opts} <- options(opts),
         :ok <- source_budget(source, parser_config),
         {:ok, quoted} <- quoted(source, parser_config),
         :ok <- quoted_budget(quoted, parser_config),
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
         {:ok, actions} <- actions(Map.get(opts, :actions, %{})),
         {:ok, state_schemas} <- state_schemas(Map.get(opts, :state_schemas, %{})) do
      {:ok, %{profile: profile, actions: actions, state_schemas: state_schemas, source: true}}
    end
  end

  defp profile(profile) when profile in [:trusted, :stored], do: {:ok, profile}

  defp profile(profile) do
    {:error,
     Error.validation_error("unsupported flow parser profile: #{inspect(profile)}", %{
       profile: profile
     })}
  end

  defp actions(actions), do: ActionRegistry.normalize(actions)

  defp state_schemas(%{} = schemas) do
    Enum.reduce_while(schemas, {:ok, %{}}, fn {identifier, schema}, {:ok, acc} ->
      with :ok <- ContractBundle.validate_identifier(identifier, :state_schemas, []),
           :ok <- Action.validate_static_data(schema),
           :ok <- Action.validate_action_schema(schema) do
        {:cont, {:ok, Map.put(acc, identifier, schema)}}
      else
        _error -> {:halt, invalid_state_schemas()}
      end
    end)
  end

  defp state_schemas(_schemas), do: invalid_state_schemas()

  defp invalid_state_schemas do
    {:error,
     Error.validation_error(
       "flow parser state_schemas must map stable identifiers to schema terms",
       %{field: :state_schemas}
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

  defp source_budget(source, %{profile: :stored}),
    do: ResourceBudget.validate_source_bytes(source)

  defp source_budget(_source, %{profile: :trusted}), do: :ok

  defp quoted_budget(quoted, %{profile: :stored}),
    do: ResourceBudget.validate(quoted, :source)

  defp quoted_budget(_quoted, %{profile: :trusted}), do: :ok

  defp operations_from_quoted({:flow, _meta, [[do: block]]}, parser_config) do
    try do
      {:ok, Jido.Flow.DSL.__parse_block__(block, __ENV__, parser_config)}
    rescue
      error in CompileError ->
        {:error, compile_error(error)}
    catch
      {:jido_flow_parser_error, error} -> {:error, error}
    end
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
