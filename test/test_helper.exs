ExUnit.start()

ExUnit.configure(
  exclude: [:integration, :skip, :authoring, :system, :load, :throughput, :property, :fuzz]
)

if Enum.any?(ExUnit.configuration()[:include], fn
     tag when tag in [:property, :fuzz] -> true
     {tag, value} when tag in [:property, :fuzz] -> value != false
     _ -> false
   end) do
  Code.require_file("property/support/report.exs", __DIR__)
  JidoActionTest.Property.Report.prepare!()
  ExUnit.configure(formatters: [ExUnit.CLIFormatter, JidoActionTest.Property.Report])
end
