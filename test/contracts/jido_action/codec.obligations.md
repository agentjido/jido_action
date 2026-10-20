---
modules:
  - Jido.Flow.Codec
  - Jido.Flow.Codec.Limits
  - Jido.Flow.Codec.Paths
  - Jido.Flow.Codec.Reader
  - Jido.Flow.Codec.Value
  - Jido.Flow.Codec.Writer
---
# Codec public promise obligations

## Purpose

Check focused facets of the [reviewed public promises](../../../guides/public-api-contract-review.md). The module reference defines the supported API. Passing tags are evidence for these facets, not complete branch or acceptance-matrix coverage.

### jido_action.codec.I5 — Version one preserves portable Flow meaning
- **scope:** `Jido.Flow.Codec.encode/1, Jido.Flow.Codec.encode/2, Jido.Flow.Codec.decode/2`
- **must:** Encode current supported components and values as deterministic JSON-compatible version-one maps. Decode them to equivalent canonical Flow meaning. Reject other document versions and unregistered write values. JSON byte order and generated identifiers across changed Flows are not stable storage promises.
- **kind:** persisted-format
- **status:** active

### jido_action.codec.I6 — Stored identifiers use the trusted Registry
- **scope:** `Jido.Flow.Codec.encode/1, Jido.Flow.Codec.encode/2, Jido.Flow.Codec.decode/2`
- **must:** Resolve stored Flow target, schema, and atom identifiers only through trusted typed host Registry entries of the required kind. Reading accepts direct aliases; writing uses the canonical identifier. Reject unknown or wrong-kind identifiers without running Action work. Generated identifiers are temporary and belong only to the exact encoded Flow.
- **kind:** security
- **status:** active

### jido_action.codec.I7 — Invalid stored data has bounded ordered diagnostics
- **scope:** `Jido.Flow.Codec.decode/2, Jido.Flow.Codec.diagnose/2`
- **must:** Reject malformed fields, unknown keys, invalid UTF-8, unsupported tags, and documents over the stated depth, width, or total-node limits. Safety checks precede envelope checks. Decode returns the first error; diagnosis returns errors from the current phase with useful JSON paths and the same semantic field order as data definitions. Never return a partial Flow.
- **kind:** security
- **status:** active
