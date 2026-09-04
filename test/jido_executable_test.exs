defmodule JidoActionTest.ExecutableTest do
  use ExUnit.Case, async: true

  alias Jido.Executable
  alias JidoActionTest.Fixtures.MathFlow

  alias JidoActionTest.Fixtures.Actions.{
    Add,
    MissingRun,
    MissingValidateOutput,
    MissingValidateParams
  }

  defmodule CallbackOnlyAction do
    def run(params, _context), do: {:ok, params}
    def validate_params(params), do: {:ok, params}
    def validate_output(output), do: {:ok, output}
  end

  defmodule InvalidDescriptor do
    def __jido_executable__ do
      Jido.Executable.action(JidoActionTest.Fixtures.Actions.Add)
    end
  end

  defmodule RaisingDescriptor do
    def __jido_executable__, do: raise("descriptor failed")
  end

  test "the Executable behaviour declares identity and validation callbacks" do
    assert Enum.sort(Executable.behaviour_info(:callbacks)) ==
             [__jido_executable__: 0, validate_output: 1, validate_params: 1]

    assert Executable.behaviour_info(:optional_callbacks) == []
    assert {:run, 2} in Jido.Action.behaviour_info(:callbacks)
  end

  test "generated Action and Flow modules implement the Executable behaviour" do
    for module <- [Add, MathFlow] do
      behaviours =
        module.__info__(:attributes) |> Keyword.get_values(:behaviour) |> List.flatten()

      assert Executable in behaviours

      for {callback, arity} <- Executable.behaviour_info(:callbacks) do
        assert function_exported?(module, callback, arity)
      end
    end
  end

  test "Action modules expose and resolve one Action descriptor" do
    assert %Executable{
             kind: :action,
             target: Add
           } = Add.__jido_executable__()

    assert {:ok, Add.__jido_executable__()} == Executable.resolve(Add)
  end

  test "Flow modules expose and resolve one Flow descriptor" do
    assert %Executable{
             kind: :flow,
             target: MathFlow
           } = MathFlow.__jido_executable__()

    assert {:ok, MathFlow.__jido_executable__()} == Executable.resolve(MathFlow)
  end

  test "inline Step wrappers expose ordinary Action descriptors" do
    for step <- JidoActionTest.Fixtures.InlineGreetingFlow.flow().components do
      action = step.action
      assert {:ok, %Executable{kind: :action, target: ^action}} = Executable.resolve(action)
      assert :ok = Executable.validate(action)
      assert action.__jido_executable__() == Executable.action(action)
    end
  end

  test "Flow artifacts resolve through the same descriptor type" do
    flow = MathFlow.flow()

    assert {:ok,
            %Executable{
              kind: :flow,
              target: ^flow
            }} = Executable.resolve(flow)
  end

  test "validation uses resolution for each public target form" do
    assert :ok = Executable.validate(Add)
    assert :ok = Executable.validate(MathFlow)
    assert :ok = Executable.validate(MathFlow.flow())
  end

  test "validation checks the common module callbacks" do
    assert {:error, missing_run} = Executable.validate(MissingRun)
    assert missing_run.message == "module is not a valid Jido executable"
    assert missing_run.details.executable == MissingRun
    assert missing_run.details.reason == "missing run/2"

    assert {:error, missing_params} = Executable.validate(MissingValidateParams)
    assert missing_params.details.executable == MissingValidateParams
    assert missing_params.details.reason == "missing validate_params/1"

    assert {:error, missing_output} = Executable.validate(MissingValidateOutput)
    assert missing_output.details.executable == MissingValidateOutput
    assert missing_output.details.reason == "missing validate_output/1"
  end

  test "callback-only modules are not executable targets" do
    assert {:error, %Jido.Action.Error.ConfigurationError{details: details}} =
             Executable.resolve(CallbackOnlyAction)

    assert details.executable == CallbackOnlyAction
    assert details.reason == :missing_descriptor
  end

  test "rejects unknown target forms with a configuration error" do
    for target <- [nil, "not executable", %{}] do
      assert {:error, %Jido.Action.Error.ConfigurationError{details: details}} =
               Executable.resolve(target)

      assert details.executable == target
    end
  end

  test "rejects a descriptor for a different target" do
    assert {:error, %Jido.Action.Error.ConfigurationError{details: details}} =
             Executable.resolve(InvalidDescriptor)

    assert details.executable == InvalidDescriptor
    assert details.reason == :invalid_descriptor
  end

  test "converts descriptor callback failures to configuration errors" do
    assert {:error, %Jido.Action.Error.ConfigurationError{details: details}} =
             Executable.resolve(RaisingDescriptor)

    assert details.executable == RaisingDescriptor
    assert details.reason == :descriptor_callback_failed
    assert %RuntimeError{message: "descriptor failed"} = details.error
  end
end
