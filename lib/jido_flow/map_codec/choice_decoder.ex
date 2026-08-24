defmodule Jido.Flow.MapCodec.ChoiceDecoder do
  @moduledoc false

  alias Jido.Flow.MapCodec.DataDecoder
  alias Jido.Flow.MapCodec.ErrorPath
  alias Jido.Flow.MapCodec.ExpressionDecoder
  alias Jido.Flow.MapCodec.RecordValidator
  alias Jido.Flow.MapCodec.RegistryLookup

  @doc false
  def decode(choice, registry) do
    with :ok <- RecordValidator.validate_choice_record(choice),
         {:ok, name} <-
           RecordValidator.fetch_required(choice, :name, "choice name is required"),
         {:ok, options} <-
           RecordValidator.fetch_required(choice, :options, "choice options are required"),
         {:ok, options} <-
           decode_options(options, registry)
           |> ErrorPath.prepend([RecordValidator.field(:options)]),
         {:ok, fallback} <-
           RecordValidator.fetch_required(choice, :fallback, "choice fallback is required"),
         {:ok, fallback} <-
           decode_fallback(fallback, registry)
           |> ErrorPath.prepend([RecordValidator.field(:fallback)]),
         {:ok, deps} <-
           RecordValidator.validate_node_deps(RecordValidator.fetch_optional(choice, :deps, [])),
         {:ok, provenance} <-
           DataDecoder.decode_optional(choice, :provenance, %{}, registry)
           |> ErrorPath.prepend([RecordValidator.field(:provenance)]) do
      {:ok,
       %{
         kind: :choice,
         name: name,
         options: options,
         fallback: fallback,
         deps: deps,
         provenance: provenance
       }}
    end
  end

  defp decode_options(options, registry) when is_list(options) do
    if List.improper?(options) do
      ErrorPath.error("choice options must be a list")
    else
      options
      |> Enum.with_index()
      |> Enum.reduce_while({:ok, []}, fn {option, index}, {:ok, acc} ->
        case decode_option(option, registry) |> ErrorPath.prepend([index]) do
          {:ok, option} -> {:cont, {:ok, [option | acc]}}
          {:error, error} -> {:halt, {:error, error}}
        end
      end)
      |> case do
        {:ok, decoded} -> {:ok, Enum.reverse(decoded)}
        {:error, error} -> {:error, error}
      end
    end
  end

  defp decode_options(_options, _registry), do: ErrorPath.error("choice options must be a list")

  defp decode_option(%{} = option, registry) do
    with :ok <- RecordValidator.validate_choice_option_record(option),
         {:ok, name} <-
           RecordValidator.fetch_required(option, :name, "choice option name is required"),
         {:ok, condition} <-
           RecordValidator.fetch_required(
             option,
             :condition,
             "choice option condition is required"
           ),
         {:ok, condition} <-
           ExpressionDecoder.decode_condition(condition, registry)
           |> ErrorPath.prepend([RecordValidator.field(:condition)]),
         {:ok, action} <-
           RecordValidator.fetch_required(option, :action, "choice option action is required"),
         {:ok, action} <-
           RegistryLookup.decode_identifier(action, :action)
           |> ErrorPath.prepend([RecordValidator.field(:action)]),
         {:ok, input} <-
           ExpressionDecoder.decode(
             RecordValidator.fetch_optional(option, :input, %{}),
             registry
           )
           |> ErrorPath.prepend([RecordValidator.field(:input)]) do
      {:ok, %{name: name, condition: condition, action: action, input: input}}
    end
  end

  defp decode_option(_option, _registry), do: ErrorPath.error("choice option must be a map")

  defp decode_fallback(%{} = fallback, registry) do
    with :ok <- RecordValidator.validate_choice_fallback_record(fallback),
         :ok <-
           validate_fallback_name(RecordValidator.fetch_optional(fallback, :name, nil))
           |> ErrorPath.prepend([RecordValidator.field(:name)]),
         {:ok, action} <-
           RecordValidator.fetch_required(
             fallback,
             :action,
             "choice fallback action is required"
           ),
         {:ok, action} <-
           RegistryLookup.decode_identifier(action, :action)
           |> ErrorPath.prepend([RecordValidator.field(:action)]),
         {:ok, input} <-
           ExpressionDecoder.decode(
             RecordValidator.fetch_optional(fallback, :input, %{}),
             registry
           )
           |> ErrorPath.prepend([RecordValidator.field(:input)]) do
      {:ok, %{action: action, input: input}}
    end
  end

  defp decode_fallback(_fallback, _registry),
    do: ErrorPath.error("choice fallback must be a map")

  defp validate_fallback_name("fallback"), do: :ok
  defp validate_fallback_name(_name), do: ErrorPath.error("choice fallback name must be fallback")
end
