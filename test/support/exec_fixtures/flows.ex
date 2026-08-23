Enum.each(
  [
    JidoTest.ExecFixtures.ChoiceEnvelopeTarget,
    JidoTest.ExecFixtures.ChoicePublicEnvelopeAction,
    JidoTest.ExecFixtures.ConcurrencyProbeAction,
    JidoTest.ExecFixtures.Transforms,
    JidoTest.TestActions.Add,
    JidoTest.TestActions.EchoParamsAction,
    JidoTest.TestActions.ErrorAction,
    JidoTest.TestActions.Multiply,
    JidoTest.TestActions.OutputEnvelopeAction
  ],
  &Code.ensure_compiled!/1
)

defmodule JidoTest.ExecFixtures.CountedValidationFlow do
  @moduledoc false
  use Jido.Flow,
    name: "counted_validation_flow",
    schema:
      Zoi.map()
      |> Zoi.transform({JidoTest.ExecFixtures.Transforms, :count, [:input]}),
    output_schema:
      Zoi.map()
      |> Zoi.transform({JidoTest.ExecFixtures.Transforms, :count, [:output]})

  flow do
    step("echo",
      action: JidoTest.TestActions.EchoParamsAction,
      params: %{value: input(:value), input_passes: input(:input_passes)}
    )
  end
end

defmodule JidoTest.ExecFixtures.ScalarTransformedOutputFlow do
  @moduledoc false
  use Jido.Flow,
    name: "scalar_transformed_output_flow",
    output_schema:
      Zoi.map()
      |> Zoi.transform({JidoTest.ExecFixtures.Transforms, :count, [:invalid_output]})

  flow do
    step("echo",
      action: JidoTest.TestActions.EchoParamsAction,
      params: %{value: input(:value)}
    )
  end
end

defmodule JidoTest.ExecFixtures.ScalarTransformedInputFlow do
  @moduledoc false
  use Jido.Flow,
    name: "scalar_transformed_input_flow",
    schema:
      Zoi.map()
      |> Zoi.transform({JidoTest.ExecFixtures.Transforms, :count, [:invalid_input]})

  flow do
    step("echo",
      action: JidoTest.TestActions.EchoParamsAction,
      params: %{value: input(:value)}
    )
  end
end

defmodule JidoTest.ExecFixtures.EnvelopeFlow do
  @moduledoc false
  use Jido.Flow,
    name: "envelope_flow",
    output_schema:
      Zoi.map()
      |> Zoi.transform({JidoTest.ExecFixtures.Transforms, :count, [:envelope_output]})

  flow do
    step("envelope",
      action: JidoTest.TestActions.OutputEnvelopeAction,
      params: %{value: input(:value)}
    )
  end
end

defmodule JidoTest.ExecFixtures.ScalarResultFlow do
  @moduledoc false
  use Jido.Flow, name: "scalar_result_flow"

  flow do
    step("echo",
      action: JidoTest.TestActions.EchoParamsAction,
      params: %{value: input(:value)}
    )

    output(select(result("echo"), [:value]))
  end
end

defmodule JidoTest.ExecFixtures.MathFlow do
  @moduledoc false
  use Jido.Flow,
    name: "math_flow",
    description: "Adds one and doubles the result"

  flow do
    step("add_one",
      action: JidoTest.TestActions.Add,
      params: %{value: input(:value), amount: 1}
    )

    step("double",
      action: JidoTest.TestActions.Multiply,
      params: %{value: select(result("add_one"), [:value]), amount: 2}
    )
  end
end

defmodule JidoTest.ExecFixtures.AsyncMathFlow do
  @moduledoc false
  use Jido.Flow,
    name: "async_math_flow",
    description: "Runs through Exec options"

  flow do
    step("add_one",
      action: JidoTest.TestActions.Add,
      params: %{value: input(:value), amount: 1}
    )
  end
end

defmodule JidoTest.ExecFixtures.NestedSerialProbeFlow do
  @moduledoc false
  use Jido.Flow, name: "nested_serial_probe_flow"

  flow do
    step("left",
      action: JidoTest.ExecFixtures.ConcurrencyProbeAction,
      params: %{side: :left, probe: input(:probe), test_pid: input(:test_pid)}
    )

    step("right",
      action: JidoTest.ExecFixtures.ConcurrencyProbeAction,
      params: %{side: :right, probe: input(:probe), test_pid: input(:test_pid)}
    )

    output(%{
      left: select(result("left"), [:side]),
      right: select(result("right"), [:side])
    })
  end
end

defmodule JidoTest.ExecFixtures.ChoiceNestedFlow do
  @moduledoc false
  use Jido.Flow,
    name: "choice_nested_flow",
    schema:
      Zoi.map()
      |> Zoi.transform({JidoTest.ExecFixtures.Transforms, :count, [:input]}),
    output_schema:
      Zoi.map()
      |> Zoi.transform({JidoTest.ExecFixtures.Transforms, :count, [:output]})

  flow do
    step("echo",
      action: JidoTest.TestActions.EchoParamsAction,
      params: %{value: input(:value), input_passes: input(:input_passes)}
    )
  end
end

defmodule JidoTest.ExecFixtures.ChoiceNestedEnvelopeFlow do
  @moduledoc false
  use Jido.Flow,
    name: "choice_nested_envelope_flow",
    schema:
      Zoi.map()
      |> Zoi.transform({JidoTest.ExecFixtures.Transforms, :count, [:input]}),
    output_schema:
      Zoi.map()
      |> Zoi.transform({JidoTest.ExecFixtures.Transforms, :count, [:envelope_output]})

  flow do
    step("envelope",
      action: JidoTest.TestActions.OutputEnvelopeAction,
      params: %{value: input(:value)}
    )
  end
end

defmodule JidoTest.ExecFixtures.ChoiceNestedErrorFlow do
  @moduledoc false
  use Jido.Flow, name: "choice_nested_error_flow"

  flow do
    step("fail",
      action: JidoTest.TestActions.ErrorAction,
      params: %{error_type: :validation}
    )
  end
end

defmodule JidoTest.ExecFixtures.ChoicePublicPaths do
  @moduledoc false
  use Jido.Flow, name: "choice_public_paths"

  flow do
    choice "route" do
      option "priority" do
        condition(input(:kind) == :priority)
        action(JidoTest.TestActions.Add)
        params(%{value: input(:value), amount: 1})
      end

      otherwise(
        action: JidoTest.TestActions.Add,
        params: %{value: input(:value), amount: 2}
      )
    end
  end
end

defmodule JidoTest.ExecFixtures.ChoiceEnvelopePublicPaths do
  @moduledoc false
  use Jido.Flow, name: "choice_envelope_public_paths"

  flow do
    choice "route" do
      option "envelope" do
        condition(input(:kind) == :envelope)
        action(JidoTest.ExecFixtures.ChoiceEnvelopeTarget)
        params(%{value: input(:value)})
      end

      otherwise(
        action: JidoTest.TestActions.Add,
        params: %{value: input(:value), amount: 0}
      )
    end
  end
end

defmodule JidoTest.ExecFixtures.ChoicePublicNestedFlow do
  @moduledoc false
  use Jido.Flow,
    name: "choice_public_nested_flow",
    schema:
      Zoi.map()
      |> Zoi.transform({JidoTest.ExecFixtures.Transforms, :count, [:input]}),
    output_schema:
      Zoi.map()
      |> Zoi.transform({JidoTest.ExecFixtures.Transforms, :count, [:output]})

  flow do
    step("echo",
      action: JidoTest.TestActions.Add,
      params: %{value: input(:value), amount: 0}
    )
  end
end

Code.ensure_compiled!(JidoTest.ExecFixtures.ChoicePublicNestedFlow)

defmodule JidoTest.ExecFixtures.ChoicePublicNestedPaths do
  @moduledoc false
  use Jido.Flow, name: "choice_public_nested_paths"

  flow do
    choice "route" do
      option "nested" do
        condition(input(:kind) == :nested)
        action(JidoTest.ExecFixtures.ChoicePublicNestedFlow)
        params(%{value: input(:value)})
      end

      otherwise(
        action: JidoTest.TestActions.Add,
        params: %{value: input(:value), amount: 0}
      )
    end
  end
end

defmodule JidoTest.ExecFixtures.ChoicePublicEnvelopeFlow do
  @moduledoc false
  use Jido.Flow,
    name: "choice_public_envelope_flow",
    schema:
      Zoi.map()
      |> Zoi.transform({JidoTest.ExecFixtures.Transforms, :count, [:input]}),
    output_schema:
      Zoi.map()
      |> Zoi.transform({JidoTest.ExecFixtures.Transforms, :count, [:envelope_output]})

  flow do
    step("envelope",
      action: JidoTest.ExecFixtures.ChoicePublicEnvelopeAction,
      params: %{value: input(:value)}
    )
  end
end

Code.ensure_compiled!(JidoTest.ExecFixtures.ChoicePublicEnvelopeFlow)

defmodule JidoTest.ExecFixtures.ChoicePublicEnvelopePaths do
  @moduledoc false
  use Jido.Flow, name: "choice_public_envelope_paths"

  flow do
    choice "route" do
      option "nested" do
        condition(input(:kind) == :nested)
        action(JidoTest.ExecFixtures.ChoicePublicEnvelopeFlow)
        params(%{value: input(:value)})
      end

      otherwise(
        action: JidoTest.TestActions.Add,
        params: %{value: input(:value), amount: 0}
      )
    end
  end
end

defmodule JidoTest.ExecFixtures.MapNestedFlow do
  @moduledoc false
  use Jido.Flow,
    name: "map_nested_flow",
    schema:
      Zoi.map()
      |> Zoi.transform({JidoTest.ExecFixtures.Transforms, :count, [:input]}),
    output_schema:
      Zoi.map()
      |> Zoi.transform({JidoTest.ExecFixtures.Transforms, :count, [:output]})

  flow do
    step("echo",
      action: JidoTest.TestActions.EchoParamsAction,
      params: %{value: input(:value), input_passes: input(:input_passes)}
    )
  end
end

defmodule JidoTest.ExecFixtures.ReduceNestedFlow do
  @moduledoc false
  use Jido.Flow,
    name: "reduce_nested_flow",
    schema:
      Zoi.map()
      |> Zoi.transform({JidoTest.ExecFixtures.Transforms, :count, [:input]}),
    output_schema:
      Zoi.map()
      |> Zoi.transform({JidoTest.ExecFixtures.Transforms, :count, [:output]})

  flow do
    step("echo",
      action: JidoTest.TestActions.EchoParamsAction,
      params: %{
        value: input(:value),
        previous: input(:previous),
        input_passes: input(:input_passes)
      }
    )
  end
end

defmodule JidoTest.ExecFixtures.InstructionTelemetryFlow do
  @moduledoc false
  use Jido.Flow, name: "instruction_telemetry_flow"

  flow do
    step("add", action: JidoTest.TestActions.Add, params: %{value: input(:value)})
  end
end

defmodule JidoTest.ExecFixtures.TelemetryChildFlow do
  @moduledoc false
  use Jido.Flow, name: "telemetry_child_flow"

  flow do
    step("child_add", action: JidoTest.TestActions.Add, params: %{value: input(:value)})
  end
end

Code.ensure_compiled!(JidoTest.ExecFixtures.TelemetryChildFlow)

defmodule JidoTest.ExecFixtures.TelemetryParentFlow do
  @moduledoc false
  use Jido.Flow, name: "telemetry_parent_flow"

  flow do
    step("child",
      action: JidoTest.ExecFixtures.TelemetryChildFlow,
      params: %{value: input(:value)}
    )
  end
end
