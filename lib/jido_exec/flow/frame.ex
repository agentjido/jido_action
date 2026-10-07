defmodule Jido.Exec.Flow.Frame do
  @moduledoc false

  @doc false
  @spec input(term()) :: {:jido_flow_input, term(), nil}
  def input(value), do: {:jido_flow_input, value, nil}

  @doc false
  @spec base_runtime_state(map(), term(), map()) :: map()
  def base_runtime_state(runtime, frame, results) do
    %{
      execution_id: runtime.execution_id,
      flow: runtime.flow,
      flow_digest: runtime.flow_digest,
      input: public_input(frame),
      input_frame: frame,
      context: runtime.context,
      results: results,
      target_runner: runtime.target_runner,
      observer: runtime.observer
    }
  end

  @doc false
  @spec value(term(), term()) :: {:jido_flow_value, term(), term()}
  def value(frame, output), do: {:jido_flow_value, frame, output}

  @doc false
  @spec value(term(), term(), [term()]) :: tuple()
  def value(frame, output, []), do: value(frame, output)
  def value(frame, output, effects), do: {:jido_flow_value, frame, output, effects}

  @doc false
  @spec effects(term()) :: [term()]
  def effects({:jido_flow_value, _frame, _output, effects}), do: effects
  def effects({:jido_flow_transition, transition}), do: transition.effects
  def effects(_value), do: []

  @doc false
  @spec unwrap_value(term()) :: term()
  def unwrap_value({:jido_flow_value, _frame, output}), do: output
  def unwrap_value({:jido_flow_value, _frame, output, _effects}), do: output
  def unwrap_value(output), do: output

  @doc false
  @spec input_of(term()) :: term()
  def input_of({:jido_flow_value, frame, _output}), do: frame
  def input_of({:jido_flow_value, frame, _output, _effects}), do: frame
  def input_of({:jido_flow_input, _input, _parent} = frame), do: frame
  def input_of(value), do: value

  @doc false
  @spec public_input(term()) :: term()
  def public_input({:jido_flow_input, input, _parent}), do: input
  def public_input(input), do: input
end
