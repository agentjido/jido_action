ExUnit.start(capture_log: true)
formatters = ExUnit.configuration()[:formatters]

# Covenant selects its formatter for checks; mutation workers start without a formatter.
covenant? = Covenant.Formatter in formatters or formatters == []

{_result, _expected_warnings} =
  Code.with_diagnostics(fn ->
    Code.require_file("support/fixtures/action/missing_callbacks.exs", __DIR__)
  end)

ExUnit.configure(
  exclude: [:integration, :skip, :authoring, :system, :load, :throughput, :property, :fuzz]
)

if covenant? do
  ExUnit.configure(include: [:property], seed: 0)
end

# Covenant tasks keep the property report from a completed normal test run.
if not covenant? and
     Enum.any?(ExUnit.configuration()[:include], fn
       tag when tag in [:property, :fuzz] -> true
       {tag, value} when tag in [:property, :fuzz] -> value != false
       _ -> false
     end) do
  Code.require_file("property/support/report.exs", __DIR__)
  JidoActionTest.Property.Report.prepare!()
  ExUnit.configure(formatters: [ExUnit.CLIFormatter, JidoActionTest.Property.Report])
end
