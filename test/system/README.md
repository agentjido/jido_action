# System verification

Run `mix test.system` from the package root. The suite has one test. It compiles
a two-Action Flow to Runic, checks its Action components, and runs it through a
Flow value and an Instruction. It checks the final result for both forms.

Managed execution, cancellation, timeout, process ownership, and recovery have
focused tests under `test/jido_exec/runner`. Generated execution checks are in
the [fuzz suite](../property/README.md). The system suite does not test external
services, Signals, Agents, or distributed storage.
