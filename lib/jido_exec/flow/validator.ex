defmodule Jido.Exec.Flow.Validator do
  @moduledoc false

  alias Jido.Action.Output
  alias Jido.Flow.Error

  @doc false
  @spec callback(module(), :validate_params | :validate_output, term()) ::
          {:ok, term()} | {:error, term()}
  def callback(module, callback, value) do
    case apply(module, callback, [value]) do
      {status, _value} = result when status in [:ok, :error] ->
        result

      result ->
        {:error,
         Error.invalid_execution_error("Flow validator returned an unsupported result", %{
           flow: module,
           callback: callback,
           result: result
         })}
    end
  rescue
    exception ->
      exception =
        if Map.has_key?(exception, :stacktrace) do
          Map.update!(exception, :stacktrace, &(&1 || __STACKTRACE__))
        else
          Map.put(exception, :stacktrace, %Splode.Stacktrace{stacktrace: __STACKTRACE__})
        end

      {:error, exception}
  catch
    kind, reason ->
      error =
        Error.invalid_execution_error("Flow validator #{kind}", %{
          flow: module,
          callback: callback,
          reason: reason
        })

      {:error, %{error | stacktrace: %Splode.Stacktrace{stacktrace: __STACKTRACE__}}}
  end

  @doc false
  @spec output_shape(module() | Jido.Flow.t(), term(), atom()) ::
          {:ok, term()} | {:error, Exception.t()}
  def output_shape(_flow, %Output{} = output, _callback), do: Output.validate(output)

  def output_shape(flow, output, callback) when is_map(output) do
    if is_struct(output) and Enumerable.impl_for(output) do
      {:error,
       Error.execution_error("Flow validator returned a value with an invalid shape", %{
         flow: flow,
         callback: callback,
         expected: :map_or_output_envelope,
         result: output
       })}
    else
      {:ok, output}
    end
  end

  def output_shape(flow, output, _callback) do
    {:error,
     Jido.Action.Error.validation_error("Action output validation must return a map", %{
       context: "Action output",
       subject: flow,
       value: output
     })}
  end
end
