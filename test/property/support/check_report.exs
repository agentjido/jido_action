Code.require_file("report.exs", __DIR__)

JidoActionTest.Property.Report.check!(
  Path.join(Mix.Project.build_path(), "property-report.json"),
  JidoActionTest.Property.Report.fuzz_ids()
)

IO.puts("Property report passed; all required fuzz cases completed.")
