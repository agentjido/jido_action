Enum.each(
  [
    JidoActionTest.ExecFixtures.ChoiceEnvelopeTarget,
    JidoActionTest.ExecFixtures.ChoicePublicEnvelopeAction,
    JidoActionTest.ExecFixtures.ConcurrencyProbeAction,
    JidoActionTest.ExecFixtures.Transforms,
    JidoActionTest.TestActions.Add,
    JidoActionTest.TestActions.EchoParamsAction,
    JidoActionTest.TestActions.ErrorAction,
    JidoActionTest.TestActions.Multiply,
    JidoActionTest.TestActions.OutputEnvelopeAction
  ],
  &Code.ensure_compiled!/1
)

defmodule JidoActionTest.ExecFixtures.CountedValidationFlow do
  @moduledoc false
  use Jido.Flow,
    name: "counted_validation_flow",
    schema:
      Zoi.map()
      |> Zoi.transform({JidoActionTest.ExecFixtures.Transforms, :count, [:input]}),
    output_schema:
      Zoi.map()
      |> Zoi.transform({JidoActionTest.ExecFixtures.Transforms, :count, [:output]})

  flow do
    step("echo",
      action: JidoActionTest.TestActions.EchoParamsAction,
      params: %{value: input(:value), input_passes: input(:input_passes)}
    )

    output(result("echo"))
  end
end

defmodule JidoActionTest.ExecFixtures.ScalarTransformedOutputFlow do
  @moduledoc false
  use Jido.Flow,
    name: "scalar_transformed_output_flow",
    output_schema:
      Zoi.map()
      |> Zoi.transform({JidoActionTest.ExecFixtures.Transforms, :count, [:invalid_output]})

  flow do
    step("echo",
      action: JidoActionTest.TestActions.EchoParamsAction,
      params: %{value: input(:value)}
    )

    output(result("echo"))
  end
end

defmodule JidoActionTest.ExecFixtures.ScalarTransformedInputFlow do
  @moduledoc false
  use Jido.Flow,
    name: "scalar_transformed_input_flow",
    schema:
      Zoi.map()
      |> Zoi.transform({JidoActionTest.ExecFixtures.Transforms, :count, [:invalid_input]})

  flow do
    step("echo",
      action: JidoActionTest.TestActions.EchoParamsAction,
      params: %{value: input(:value)}
    )

    output(result("echo"))
  end
end

defmodule JidoActionTest.ExecFixtures.EnvelopeFlow do
  @moduledoc false
  use Jido.Flow,
    name: "envelope_flow",
    output_schema:
      Zoi.map()
      |> Zoi.transform({JidoActionTest.ExecFixtures.Transforms, :count, [:envelope_output]})

  flow do
    step("envelope",
      action: JidoActionTest.TestActions.OutputEnvelopeAction,
      params: %{value: input(:value)}
    )

    output(result("envelope"))
  end
end

defmodule JidoActionTest.ExecFixtures.ScalarResultFlow do
  @moduledoc false
  use Jido.Flow, name: "scalar_result_flow"

  flow do
    step("echo",
      action: JidoActionTest.TestActions.EchoParamsAction,
      params: %{value: input(:value)}
    )

    output(select(result("echo"), [:value]))
  end
end

defmodule JidoActionTest.ExecFixtures.MathFlow do
  @moduledoc false
  use Jido.Flow,
    name: "math_flow",
    description: "Adds one and doubles the result"

  flow do
    step("add_one",
      action: JidoActionTest.TestActions.Add,
      params: %{value: input(:value), amount: 1}
    )

    step("double",
      action: JidoActionTest.TestActions.Multiply,
      params: %{value: select(result("add_one"), [:value]), amount: 2}
    )

    output(result("double"))
  end
end

defmodule JidoActionTest.ExecFixtures.AsyncMathFlow do
  @moduledoc false
  use Jido.Flow,
    name: "async_math_flow",
    description: "Runs through Exec options"

  flow do
    step("add_one",
      action: JidoActionTest.TestActions.Add,
      params: %{value: input(:value), amount: 1}
    )

    output(result("add_one"))
  end
end

defmodule JidoActionTest.ExecFixtures.NestedSerialProbeFlow do
  @moduledoc false
  use Jido.Flow, name: "nested_serial_probe_flow"

  flow do
    step("left",
      action: JidoActionTest.ExecFixtures.ConcurrencyProbeAction,
      params: %{side: :left, probe: input(:probe), test_pid: input(:test_pid)}
    )

    step("right",
      action: JidoActionTest.ExecFixtures.ConcurrencyProbeAction,
      params: %{side: :right, probe: input(:probe), test_pid: input(:test_pid)}
    )

    output(%{
      left: select(result("left"), [:side]),
      right: select(result("right"), [:side])
    })
  end
end

defmodule JidoActionTest.ExecFixtures.ChoiceNestedFlow do
  @moduledoc false
  use Jido.Flow,
    name: "choice_nested_flow",
    schema:
      Zoi.map()
      |> Zoi.transform({JidoActionTest.ExecFixtures.Transforms, :count, [:input]}),
    output_schema:
      Zoi.map()
      |> Zoi.transform({JidoActionTest.ExecFixtures.Transforms, :count, [:output]})

  flow do
    step("echo",
      action: JidoActionTest.TestActions.EchoParamsAction,
      params: %{value: input(:value), input_passes: input(:input_passes)}
    )

    output(result("echo"))
  end
end

defmodule JidoActionTest.ExecFixtures.ChoiceNestedEnvelopeFlow do
  @moduledoc false
  use Jido.Flow,
    name: "choice_nested_envelope_flow",
    schema:
      Zoi.map()
      |> Zoi.transform({JidoActionTest.ExecFixtures.Transforms, :count, [:input]}),
    output_schema:
      Zoi.map()
      |> Zoi.transform({JidoActionTest.ExecFixtures.Transforms, :count, [:envelope_output]})

  flow do
    step("envelope",
      action: JidoActionTest.TestActions.OutputEnvelopeAction,
      params: %{value: input(:value)}
    )

    output(result("envelope"))
  end
end

defmodule JidoActionTest.ExecFixtures.ChoiceNestedErrorFlow do
  @moduledoc false
  use Jido.Flow, name: "choice_nested_error_flow"

  flow do
    step("fail",
      action: JidoActionTest.TestActions.ErrorAction,
      params: %{error_type: :validation}
    )

    output(result("fail"))
  end
end

defmodule JidoActionTest.ExecFixtures.ChoicePublicPaths do
  @moduledoc false
  use Jido.Flow, name: "choice_public_paths"

  flow do
    choice "route" do
      option "priority" do
        condition(input(:kind) == :priority)
        action(JidoActionTest.TestActions.Add)
        params(%{value: input(:value), amount: 1})
      end

      otherwise(
        action: JidoActionTest.TestActions.Add,
        params: %{value: input(:value), amount: 2}
      )
    end

    output(result("route"))
  end
end

defmodule JidoActionTest.ExecFixtures.ChoiceEnvelopePublicPaths do
  @moduledoc false
  use Jido.Flow, name: "choice_envelope_public_paths"

  flow do
    choice "route" do
      option "envelope" do
        condition(input(:kind) == :envelope)
        action(JidoActionTest.ExecFixtures.ChoiceEnvelopeTarget)
        params(%{value: input(:value)})
      end

      otherwise(
        action: JidoActionTest.TestActions.Add,
        params: %{value: input(:value), amount: 0}
      )
    end

    output(result("route"))
  end
end

defmodule JidoActionTest.ExecFixtures.ChoicePublicNestedFlow do
  @moduledoc false
  use Jido.Flow,
    name: "choice_public_nested_flow",
    schema:
      Zoi.map()
      |> Zoi.transform({JidoActionTest.ExecFixtures.Transforms, :count, [:input]}),
    output_schema:
      Zoi.map()
      |> Zoi.transform({JidoActionTest.ExecFixtures.Transforms, :count, [:output]})

  flow do
    step("echo",
      action: JidoActionTest.TestActions.Add,
      params: %{value: input(:value), amount: 0}
    )

    output(result("echo"))
  end
end

Code.ensure_compiled!(JidoActionTest.ExecFixtures.ChoicePublicNestedFlow)

defmodule JidoActionTest.ExecFixtures.ChoicePublicNestedPaths do
  @moduledoc false
  use Jido.Flow, name: "choice_public_nested_paths"

  flow do
    choice "route" do
      option "nested" do
        condition(input(:kind) == :nested)
        action(JidoActionTest.TestActions.Add)
        params(%{value: input(:value)})
      end

      otherwise(
        action: JidoActionTest.TestActions.Add,
        params: %{value: input(:value), amount: 0}
      )
    end

    output(result("route"))
  end
end

defmodule JidoActionTest.ExecFixtures.ChoicePublicEnvelopeFlow do
  @moduledoc false
  use Jido.Flow,
    name: "choice_public_envelope_flow",
    schema:
      Zoi.map()
      |> Zoi.transform({JidoActionTest.ExecFixtures.Transforms, :count, [:input]}),
    output_schema:
      Zoi.map()
      |> Zoi.transform({JidoActionTest.ExecFixtures.Transforms, :count, [:envelope_output]})

  flow do
    step("envelope",
      action: JidoActionTest.ExecFixtures.ChoicePublicEnvelopeAction,
      params: %{value: input(:value)}
    )

    output(result("envelope"))
  end
end

Code.ensure_compiled!(JidoActionTest.ExecFixtures.ChoicePublicEnvelopeFlow)

defmodule JidoActionTest.ExecFixtures.ChoicePublicEnvelopePaths do
  @moduledoc false
  use Jido.Flow, name: "choice_public_envelope_paths"

  flow do
    choice "route" do
      option "nested" do
        condition(input(:kind) == :nested)
        action(JidoActionTest.ExecFixtures.ChoicePublicEnvelopeAction)
        params(%{value: input(:value)})
      end

      otherwise(
        action: JidoActionTest.TestActions.Add,
        params: %{value: input(:value), amount: 0}
      )
    end

    output(result("route"))
  end
end

defmodule JidoActionTest.ExecFixtures.MapNestedFlow do
  @moduledoc false
  use Jido.Flow,
    name: "map_nested_flow",
    schema:
      Zoi.map()
      |> Zoi.transform({JidoActionTest.ExecFixtures.Transforms, :count, [:input]}),
    output_schema:
      Zoi.map()
      |> Zoi.transform({JidoActionTest.ExecFixtures.Transforms, :count, [:output]})

  flow do
    step("echo",
      action: JidoActionTest.TestActions.EchoParamsAction,
      params: %{value: input(:value), input_passes: input(:input_passes)}
    )

    output(result("echo"))
  end
end

defmodule JidoActionTest.ExecFixtures.ReduceNestedFlow do
  @moduledoc false
  use Jido.Flow,
    name: "reduce_nested_flow",
    schema:
      Zoi.map()
      |> Zoi.transform({JidoActionTest.ExecFixtures.Transforms, :count, [:input]}),
    output_schema:
      Zoi.map()
      |> Zoi.transform({JidoActionTest.ExecFixtures.Transforms, :count, [:output]})

  flow do
    step("echo",
      action: JidoActionTest.TestActions.EchoParamsAction,
      params: %{
        value: input(:value),
        previous: input(:previous),
        input_passes: input(:input_passes)
      }
    )

    output(result("echo"))
  end
end

defmodule JidoActionTest.ExecFixtures.InstructionTelemetryFlow do
  @moduledoc false
  use Jido.Flow, name: "instruction_telemetry_flow"

  flow do
    step("add", action: JidoActionTest.TestActions.Add, params: %{value: input(:value)})
    output(result("add"))
  end
end

defmodule JidoActionTest.ExecFixtures.TelemetryChildFlow do
  @moduledoc false
  use Jido.Flow, name: "telemetry_child_flow"

  flow do
    step("child_add", action: JidoActionTest.TestActions.Add, params: %{value: input(:value)})
    output(result("child_add"))
  end
end

Code.ensure_compiled!(JidoActionTest.ExecFixtures.TelemetryChildFlow)

defmodule JidoActionTest.ExecFixtures.TelemetryParentFlow do
  @moduledoc false
  use Jido.Flow, name: "telemetry_parent_flow"

  flow do
    step("child",
      action: JidoActionTest.ExecFixtures.TelemetryChildFlow,
      params: %{value: input(:value)}
    )

    output(result("child"))
  end
end
