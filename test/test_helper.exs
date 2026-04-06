# Prepare modules for Mimic
Enum.each(
  [
    :telemetry,
    System,
    Req,
    Jido.Exec
  ],
  &Mimic.copy/1
)

ExUnit.start()

ExUnit.configure(capture_log: true, exclude: [:skip])
