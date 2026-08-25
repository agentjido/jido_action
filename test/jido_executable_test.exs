defmodule JidoActionTest.ExecutableTest do
  use ExUnit.Case, async: true

  alias Jido.Executable
  alias JidoActionTest.ExecFixtures.MathFlow
  alias JidoActionTest.TestActions.Add

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
end
