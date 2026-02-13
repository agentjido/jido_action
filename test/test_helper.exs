require Logger
# Prepare modules for Mimic
Enum.each(
  [
    :telemetry,
    System,
    Req,
    Jido.Exec,
    Tentacat.Issues,
    Tentacat.Pulls,
    Tentacat.Issues.Comments,
    Tentacat.Hooks
  ],
  &Mimic.copy/1
)

# Suite requires debug level for all tests
Logger.configure(level: :debug)

ExUnit.start()

ExUnit.configure(capture_log: true, exclude: [:skip])
