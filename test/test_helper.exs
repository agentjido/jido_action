ExUnit.start(capture_log: true)
covenant_pilot? = System.get_env("JIDO_COVENANT_PILOT") == "1"

{_result, _expected_warnings} =
  Code.with_diagnostics(fn ->
    Code.require_file("support/fixtures/action/missing_callbacks.exs", __DIR__)
  end)

ExUnit.configure(
  exclude: [:integration, :skip, :authoring, :system, :load, :throughput, :property, :fuzz]
)

if covenant_pilot? do
  ExUnit.configure(include: [:property], seed: 0)
end

# Covenant tasks use their own formatters. The pilot must not reset the report
# from a completed property run. Normal property runs keep their report setup.
if not covenant_pilot? and
     Enum.any?(ExUnit.configuration()[:include], fn
       tag when tag in [:property, :fuzz] -> true
       {tag, value} when tag in [:property, :fuzz] -> value != false
       _ -> false
     end) do
  Code.require_file("property/support/report.exs", __DIR__)
  JidoActionTest.Property.Report.prepare!()
  ExUnit.configure(formatters: [ExUnit.CLIFormatter, JidoActionTest.Property.Report])
end

if covenant_pilot? do
  ExUnit.configure(
    formatters: Enum.uniq(ExUnit.configuration()[:formatters] ++ [Covenant.Formatter])
  )
end
