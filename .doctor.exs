%Doctor.Config{
  # Doctor 0.23.0 counts quoted Action, body, and index definitions as exports.
  # InlineTest checks these modules' actual BEAM docs and function specs instead.
  # This exception does not change runtime test coverage or its threshold.
  ignore_modules: [Jido.Action.Inline.Compiler, Jido.Action.Inline.Owner],
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
