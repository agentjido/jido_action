defmodule JidoActionTest.ExecutableTest do
  use ExUnit.Case, async: true

  alias Jido.Executable
  alias JidoActionTest.ExecFixtures.MathFlow
  alias JidoActionTest.TestActions.Add

  defmodule CallbackOnlyAction do
    def run(params, _context), do: {:ok, params}
    def validate_params(params), do: {:ok, params}
    def validate_output(output), do: {:ok, output}
  end

  defmodule InvalidDescriptor do
    def __jido_executable__ do
      Jido.Executable.action(JidoActionTest.TestActions.Add)
    end
  end

  defmodule RaisingDescriptor do
    def __jido_executable__, do: raise("descriptor failed")
  end

  test "Action modules expose and resolve one Action descriptor" do
    assert %Executable{
             kind: :action,
             target: Add,
             adapter: Jido.Exec.ActionAdapter
           } = Add.__jido_executable__()

    assert {:ok, Add.__jido_executable__()} == Executable.resolve(Add)
  end

  test "Flow modules expose and resolve one Flow descriptor" do
    assert %Executable{
             kind: :flow,
             target: MathFlow,
             adapter: Jido.Exec.FlowAdapter
           } = MathFlow.__jido_executable__()

    assert {:ok, MathFlow.__jido_executable__()} == Executable.resolve(MathFlow)
  end

  test "Flow artifacts resolve through the same descriptor type" do
    flow = MathFlow.flow()

    assert {:ok,
            %Executable{
              kind: :flow,
              target: ^flow,
              adapter: Jido.Exec.FlowAdapter
            }} = Executable.resolve(flow)
  end

  test "validation uses resolution for each public target form" do
    assert :ok = Executable.validate(Add)
    assert :ok = Executable.validate(MathFlow)
    assert :ok = Executable.validate(MathFlow.flow())
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
