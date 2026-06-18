# Prepare modules for Mimic
Enum.each(
  [
    :telemetry,
    System,
    Req
  ],
  &Mimic.copy/1
)

ExUnit.start()

ExUnit.configure(exclude: [:skip])
