%Doctor.Config{
  # Doctor 0.23.0 assigns definitions inside quoted code to these compiler
  # modules. It cannot associate the adjacent generated docs and specs.
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
