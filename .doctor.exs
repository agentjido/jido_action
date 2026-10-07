%Doctor.Config{
  # Doctor 0.23.0 counts quoted Action, body, and index definitions as exports.
  # InlineTest checks these modules' actual BEAM docs and function specs instead.
  # This exception does not change runtime test coverage or its threshold.
  ignore_modules: [
    Jido.Action.Inline.Compiler,
    Jido.Action.Inline.Owner,
    Jido.Exec.ActionNode,
    Jido.Exec.ChoiceNode,
    Jido.Exec.ChoiceNode.Branch,
    Jido.Exec.ChoiceNode.Selector,
    Jido.Exec.Compiler,
    Jido.Exec.DispatchNode,
    Jido.Exec.DispatchNode.Finish,
    Jido.Exec.Executor,
    Jido.Exec.FlowInputNode,
    Jido.Exec.Frame,
    Jido.Exec.LoopNode,
    Jido.Exec.LoopNode.Start,
    Jido.Exec.MapNode,
    Jido.Exec.MapNode.Collection,
    Jido.Exec.OutputNode,
    Jido.Exec.Portable,
    Jido.Exec.Source,
    Jido.Exec.ValueResolver
  ],
  min_module_doc_coverage: 100,
  min_module_spec_coverage: 100,
  min_overall_doc_coverage: 100,
  min_overall_moduledoc_coverage: 100,
  min_overall_spec_coverage: 100,
  exception_moduledoc_required: true,
  raise: true,
  reporter: Doctor.Reporters.Full,
  struct_type_spec_required: true,
  umbrella: false
}
