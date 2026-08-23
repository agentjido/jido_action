defmodule Jido.Flow.Element.Validation do
  @moduledoc false

  alias Jido.Action
  alias Jido.Action.Error
  alias Jido.Flow.Expression

  @type owner :: :node | :choice | :map | :reduce | :iterator

  @doc false
  @spec name(term(), owner(), [term()] | nil) :: {:ok, String.t()} | {:error, Exception.t()}
  def name(value, owner, path \\ nil)

  def name(value, owner, path) when is_atom(value) and not is_nil(value) do
    value |> Atom.to_string() |> name(owner, path)
  end

  def name(value, owner, path) when is_binary(value) do
    case Action.validate_name(value) do
      :ok -> {:ok, value}
      {:error, message} -> invalid_name(owner, path, message)
    end
  end

  def name(_value, owner, path), do: invalid_name(owner, path, nil)

  @doc false
  @spec target(term(), owner() | {:label, String.t()}, [term()] | nil) ::
          {:ok, module()} | {:error, Exception.t()}
  def target(value, _owner, _path) when is_atom(value) and not is_nil(value), do: {:ok, value}

  def target(_value, owner, path) do
    validation_error(target_message(owner), path)
  end

  @doc false
  @spec deps(term(), owner()) :: {:ok, [String.t()]} | {:error, Exception.t()}
  def deps(nil, _owner), do: {:ok, []}

  def deps(values, owner) when is_list(values) do
    if List.improper?(values) do
      deps_error(owner, "#{owner_label(owner)} deps must be a proper list")
    else
      normalize_deps(values, owner)
    end
  end

  def deps(_values, owner), do: deps_error(owner, "#{owner_label(owner)} deps must be a list")

  @doc false
  @spec provenance(term(), owner()) :: {:ok, map()} | {:error, Exception.t()}
  def provenance(nil, _owner), do: {:ok, %{}}
  def provenance(value, _owner) when is_map(value), do: {:ok, value}

  def provenance(_value, owner) do
    validation_error(
      "#{owner_label(owner)} provenance must be a map",
      owner_path(owner, :provenance)
    )
  end

  @doc false
  @spec known_keys(map(), [atom()], String.t(), [term()] | nil) :: :ok | {:error, Exception.t()}
  def known_keys(attrs, allowed, owner, path \\ []) do
    case attrs |> Map.keys() |> Enum.find(&(&1 not in allowed)) do
      nil ->
        :ok

      key ->
        details = if is_list(path), do: %{key: key, path: path ++ [key]}, else: %{key: key}

        {:error,
         Error.validation_error(
           "unknown #{owner} configuration key: #{inspect(key)}",
           details
         )}
    end
  end

  @doc false
  @spec expression(term(), Jido.Flow.Ref.scope(), String.t(), [term()], keyword()) ::
          {:ok, term()} | {:error, Exception.t()}
  def expression(value, scope, owner, path, opts \\ []) do
    with {:ok, value} <- Expression.normalize(value),
         :ok <- Expression.validate(value, scope),
         :ok <- validate_static(value, opts) do
      {:ok, value}
    else
      {:error, error} -> {:error, translate_expression_error(error, owner, path)}
    end
  end

  defp invalid_name(:node, _path, message) when is_binary(message) do
    {:error, Error.validation_error(message)}
  end

  defp invalid_name(:choice, path, message) when is_binary(message) do
    {:error, Error.validation_error(message, %{path: path || [:name]})}
  end

  defp invalid_name(owner, path, _message) do
    validation_error(
      "#{owner_label(owner)} name must be a non-empty string or atom",
      path || owner_path(owner, :name)
    )
  end

  defp target_message(:node), do: "node action must be a module atom"
  defp target_message({:label, label}), do: "#{label} target must be a module atom"
  defp target_message(owner), do: "#{owner_label(owner)} target must be a module atom"

  defp normalize_deps(values, owner) do
    values
    |> Enum.reduce_while({:ok, []}, fn value, {:ok, acc} ->
      case dependency_name(value) do
        {:ok, name} ->
          {:cont, {:ok, [name | acc]}}

        :error ->
          {:halt, deps_error(owner, "#{owner_label(owner)} deps must be a list of step names")}
      end
    end)
    |> case do
      {:ok, deps} -> {:ok, deps |> Enum.uniq() |> Enum.sort()}
      {:error, error} -> {:error, error}
    end
  end

  defp dependency_name(value) when is_atom(value) and not is_nil(value) do
    value |> Atom.to_string() |> dependency_name()
  end

  defp dependency_name(value) when is_binary(value) do
    case Action.validate_name(value) do
      :ok -> {:ok, value}
      {:error, _message} -> :error
    end
  end

  defp dependency_name(_value), do: :error

  defp deps_error(owner, message), do: validation_error(message, owner_path(owner, :deps))

  defp validate_static(value, opts) do
    if Keyword.get(opts, :static, false) do
      case Action.validate_static_data(value) do
        :ok -> :ok
        {:error, _reason} -> {:error, Error.validation_error("expression is not static")}
      end
    else
      :ok
    end
  end

  defp translate_expression_error(error, owner, path) do
    details = Map.get(error, :details, %{})
    nested_path = path ++ Map.get(details, :path, [])

    case Expression.error_kind(error) do
      :invalid_scope ->
        Error.validation_error(
          "flow expression contains a scoped ref outside its valid scope",
          %{path: nested_path, ref_type: details.ref_type, scope: details.scope}
        )

      :invalid_ref_path ->
        Error.validation_error("#{owner} contains invalid ref path", %{
          path: nested_path,
          segment: details.segment
        })

      :invalid_ref ->
        Error.validation_error("#{owner} contains invalid ref", %{
          path: nested_path,
          type: details.type
        })

      :improper_list ->
        Error.validation_error("#{owner} must be a proper list", %{path: nested_path})

      :unsupported_expression ->
        Error.validation_error("#{owner} contains unsupported expression", %{
          path: nested_path,
          expression: details.expression
        })

      :other ->
        Error.validation_error("#{owner} must be static module data", %{path: path})
    end
  end

  defp validation_error(message, nil), do: {:error, Error.validation_error(message)}

  defp validation_error(message, path),
    do: {:error, Error.validation_error(message, %{path: path})}

  defp owner_label(:node), do: "node"
  defp owner_label(:choice), do: "choice"
  defp owner_label(:map), do: "map"
  defp owner_label(:reduce), do: "reduce"
  defp owner_label(:iterator), do: "iterator"

  defp owner_path(:node, _field), do: nil
  defp owner_path(_owner, field), do: [field]
end
