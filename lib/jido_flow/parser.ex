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

  @doc """
  Parses trusted Flow source into a canonical `%Jido.Flow{}`.
  """
  @spec parse(String.t(), map() | keyword()) :: {:ok, Flow.t()} | {:error, Exception.t()}
  def parse(source, opts \\ [])

  def parse(source, opts) when is_binary(source) do
    with {:ok, quoted} <- quoted(source),
         {:ok, operations} <- operations_from_quoted(quoted),
         {:ok, config} <- config(opts) do
      config
      |> Syntax.new()
      |> Map.put(:operations, operations)
      |> Lowerer.lower()
    end
  end

  def parse(_source, _opts), do: {:error, Error.validation_error("flow source must be a string")}

  defp quoted(source) do
    case Code.string_to_quoted(source, columns: true, token_metadata: true) do
      {:ok, quoted} ->
        {:ok, quoted}

      {:error, {line, error, token}} ->
        {:error,
         Error.validation_error("invalid flow source: #{format_parse_error(error, token)}", %{
           line: line
         })}
    end
  end

  defp operations_from_quoted({:flow, _meta, [[do: block]]}) do
    {:ok, Jido.Flow.DSL.__parse_block__(block, __ENV__)}
  rescue
    error in CompileError ->
      {:error, compile_error(error)}
  end

  defp operations_from_quoted(quoted) do
    {:error,
     Error.validation_error("flow source must contain a single flow do block", %{
       form: Macro.to_string(quoted)
     })}
  end

  defp config(opts) when is_list(opts) do
    opts
    |> Map.new()
    |> config()
  end

  defp config(%{} = opts), do: Flow.__validate_config__(opts)

  defp config(_opts) do
    {:error, Error.validation_error("flow parser options must be a map or keyword list")}
  end

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
