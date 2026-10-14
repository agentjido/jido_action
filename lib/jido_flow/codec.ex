defmodule Jido.Flow.Codec do
  @moduledoc """
  Encodes and decodes the stored Flow document.

  The document contains JSON-compatible data. A trusted `Jido.Flow.Registry`
  resolves all Action, Flow, schema, and user-data atom identifiers.

  See the [storage guide](flow-storage.md) for document version, operation
  tags, and validation limits.

      registry =
        Jido.Flow.Registry.new!(%{
          "actions/send" => {:action, MyApp.SendNotice},
          "schemas/none" => {:schema, []}
        })

      {:ok, document} = Jido.Flow.Codec.encode(flow, registry)
      {:ok, decoded_flow} = Jido.Flow.Codec.decode(document, registry)

      {:ok, temporary_document, temporary_registry} =
        Jido.Flow.Codec.encode(flow)

      case Jido.Flow.Codec.diagnose(editor_document, registry) do
        {:ok, flow} -> {:ok, flow}
        {:error, errors} -> {:error, Jido.Flow.Error.to_map(errors)}
      end
  """

  alias Jido.Flow
  alias Jido.Flow.{Definition, Error, Registry}
  alias Jido.Flow.Codec.{Paths, Reader, Writer}

  @type document :: %{required(String.t()) => term()}

  @doc "Encodes a canonical Flow with a generated convenience Registry."
  @spec encode(Flow.t()) :: {:ok, document(), Registry.t()} | {:error, Exception.t()}
  def encode(flow) do
    with {:ok, flow} <- Flow.validate(flow),
         {:ok, registry} <- flow |> Registry.entries() |> Registry.new(),
         {:ok, document} <- Writer.encode(flow, registry) do
      {:ok, document, registry}
    end
  end

  @doc "Encodes a canonical Flow as a version 1 stored document."
  @spec encode(Flow.t(), Registry.t()) :: {:ok, document()} | {:error, Exception.t()}
  def encode(%Flow{} = flow, %Registry{} = registry) do
    with {:ok, flow} <- Flow.validate(flow), do: Writer.encode(flow, registry)
  end

  def encode(value, %Registry{}),
    do: {:error, Error.validation_error("expected a Jido.Flow artifact", %{value: value})}

  def encode(_flow, registry),
    do:
      {:error,
       Error.validation_error("flow codec registry must be a Jido.Flow.Registry", %{
         value: registry
       })}

  @doc "Decodes a stored Flow through a trusted Registry and returns the first validation error."
  @spec decode(document(), Registry.t()) :: {:ok, Flow.t()} | {:error, Exception.t()}
  def decode(document, registry) do
    case diagnose(document, registry) do
      {:ok, flow} -> {:ok, flow}
      {:error, %Error.Invalid{errors: [error | _]}} -> {:error, error}
    end
  end

  @doc "Diagnoses a stored Flow with the same validation rules and error order as data authoring."
  @spec diagnose(document(), Registry.t()) :: {:ok, Flow.t()} | {:error, Error.Invalid.t()}
  def diagnose(document, %Registry{} = registry) do
    case Reader.decode(document, registry) do
      {:ok, attrs, paths} ->
        case Definition.diagnose_lowered(attrs) do
          {:ok, attrs} ->
            {:ok, struct!(Flow, attrs)}

          {:error, issues} ->
            errors =
              Enum.map(issues, fn issue ->
                error = %{
                  issue.error
                  | details: Map.put(issue.error.details, :path, issue.location)
                }

                Paths.error(error, paths)
              end)

            failure(errors)
        end

      {:error, errors} ->
        failure(errors)
    end
  end

  def diagnose(_document, registry),
    do:
      failure([
        Error.validation_error("flow codec registry must be a Jido.Flow.Registry", %{
          value: registry
        })
      ])

  defp failure(errors), do: {:error, %Error.Invalid{errors: errors}}
end
