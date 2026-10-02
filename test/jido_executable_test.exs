defmodule JidoActionTest.ExecutableTest do
  use ExUnit.Case, async: false

  alias Jido.Executable
  alias Jido.{Exec, Flow, Instruction}
  alias Jido.Flow.{Ref, Subflow}
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

  defmodule FlowWithoutRun do
    @behaviour Jido.Executable

    @impl true
    def __jido_executable__, do: Executable.flow(__MODULE__)
    def flow, do: MathFlow.flow()
    @impl true
    defdelegate validate_params(params), to: MathFlow
    @impl true
    defdelegate validate_output(output), to: MathFlow
  end

  defmodule ContinueToFlow do
    use Jido.Action, name: "continue_to_flow_without_run"

    @impl true
    def run(params, _context), do: {:continue, params, FlowWithoutRun}
  end

  defmodule MissingFlowDefinition do
    def __jido_executable__, do: Executable.flow(__MODULE__)
    def validate_params(params), do: {:ok, params}
    def validate_output(output), do: {:ok, output}
  end

  defmodule MissingFlowParams do
    def __jido_executable__, do: Executable.flow(__MODULE__)
    def flow, do: MathFlow.flow()
    def validate_output(output), do: {:ok, output}
  end

  defmodule MissingFlowOutput do
    def __jido_executable__, do: Executable.flow(__MODULE__)
    def flow, do: MathFlow.flow()
    def validate_params(params), do: {:ok, params}
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
      assert Jido.Action in behaviours == (module == Add)

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

  for {kind, callback} <- [
        action: quote(do: def(run(params, _context), do: {:ok, params})),
        flow: quote(do: def(flow(), do: JidoActionTest.Fixtures.MathFlow.flow()))
      ] do
    @kind kind
    @target_callback callback
    @tag :tmp_dir
    test "validation loads an unloaded #{@kind} descriptor target", %{tmp_dir: tmp_dir} do
      module = Module.concat(__MODULE__, "Unloaded#{@kind}")

      definition =
        quote do
          def __jido_executable__,
            do: %Jido.Executable{kind: unquote(@kind), target: __MODULE__}

          def validate_params(params), do: {:ok, params}
          def validate_output(output), do: {:ok, output}
          unquote(@target_callback)
        end

      {:module, ^module, beam, _value} = Module.create(module, definition, __ENV__)
      File.write!(Path.join(tmp_dir, Atom.to_string(module) <> ".beam"), beam)
      Code.prepend_path(tmp_dir)

      on_exit(fn ->
        Code.delete_path(tmp_dir)
        :code.delete(module)
        :code.purge(module)
      end)

      :code.delete(module)
      :code.purge(module)
      assert :code.is_loaded(module) == false

      descriptor = %Executable{kind: @kind, target: module}
      assert :ok = Executable.validate(descriptor)
      assert {:ok, ^descriptor} = Executable.resolve(module)
      if @kind == :flow, do: refute(function_exported?(module, :run, 2))
    end
  end

  test "descriptor validation retains errors for missing modules and callbacks" do
    for {kind, module, callback} <- [
          {:action, __MODULE__.UnknownExecutable, "run/2"},
          {:flow, __MODULE__.UnknownExecutable, "flow/0"},
          {:action, MissingRun, "run/2"},
          {:action, MissingValidateParams, "validate_params/1"},
          {:action, MissingValidateOutput, "validate_output/1"},
          {:flow, MissingFlowDefinition, "flow/0"},
          {:flow, MissingFlowParams, "validate_params/1"},
          {:flow, MissingFlowOutput, "validate_output/1"}
        ] do
      assert {:error, %Jido.Action.Error.InvalidInputError{} = error} =
               Executable.validate(%Executable{kind: kind, target: module})

      assert error.message == "module is not a valid Jido executable"
      assert error.details == %{executable: module, reason: "missing #{callback}"}
    end
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

  test "Flow validation requires definition and validation callbacks, without run/2" do
    refute function_exported?(FlowWithoutRun, :run, 2)
    assert :ok = Executable.validate(FlowWithoutRun)

    for {module, reason} <- [
          {MissingFlowDefinition, "missing flow/0"},
          {MissingFlowParams, "missing validate_params/1"},
          {MissingFlowOutput, "missing validate_output/1"}
        ] do
      assert {:error, error} = Executable.validate(module)
      assert error.message == "module is not a valid Jido executable"
      assert error.details == %{executable: module, reason: reason}
    end
  end

  test "a Flow without run/2 executes through every public entry" do
    input = %{value: 3}
    expected = {:ok, %{value: 8}}
    instruction = Instruction.new!(target: FlowWithoutRun, params: input)

    parent =
      Flow.new!(
        name: "flow_without_run_parent",
        components: [Subflow.new!(name: "child", flow: FlowWithoutRun, params: Ref.input([]))],
        output: Ref.result("child")
      )

    assert Exec.run(FlowWithoutRun, input) == expected
    assert Exec.run(instruction) == expected
    assert Exec.run(parent, input) == expected
    assert Exec.run(ContinueToFlow, input) == expected
    assert FlowWithoutRun |> Exec.run_async(input) |> Exec.await() == expected

    for target <- [FlowWithoutRun, instruction, parent] do
      assert {:ok, execution} = Exec.start(target, input)
      assert {:ok, execution} = Exec.continue(execution)
      assert Exec.result(execution) == expected
    end
  end

  test "generated Flow run/2 is a convenience call through Exec" do
    assert MathFlow.run(%{value: 3}, %{}) == Exec.run(MathFlow, %{value: 3})
    assert MathFlow.run(%{value: "bad"}, %{}) == Exec.run(MathFlow, %{value: "bad"})
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
