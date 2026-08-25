%Doctor.Config{
  # Doctor 0.23 cannot parse `def unquote(:in)`. ExDoc checks these modules.
  ignore_modules: [Jido.Flow.Builder, Jido.Flow.Condition],
  ignore_paths: [
    ~r{^deps/},
    ~r{^lib/jido_action/(application|telemetry|validation)\.ex$},
    ~r{^lib/jido_exec/(?!execution\.ex$|supervisor\.ex$).+\.ex$},
    ~r{^lib/jido_flow/dsl/},
    ~r{^lib/jido_flow/compiler(?:\.ex|/)},
    ~r{^lib/jido_flow/(graph|identity|validation)\.ex$}
  ],
  min_module_doc_coverage: 100,
  min_module_spec_coverage: 0,
  min_overall_doc_coverage: 100,
  min_overall_moduledoc_coverage: 100,
  # This threshold applies to the modules that Doctor can parse. Builder and
  # Condition are checked by ExDoc because Doctor 0.23 cannot parse their
  # quoted `in` definitions.
  min_overall_spec_coverage: 85,
  exception_moduledoc_required: true,
  raise: true,
  reporter: Doctor.Reporters.Full,
  struct_type_spec_required: true,
  umbrella: false
}
