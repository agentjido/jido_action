---
modules: [Jido.Action.Inline, Jido.Action.Inline.Parser, Jido.Action.Inline.Compiler, Jido.Action.Inline.Owner, Jido.Authoring.Options]
---
# Inline Action obligations

## Purpose

These obligations refine `ACT-005` and the trusted host target boundary.
The public Inline module documentation is the API source.

### jido_action.inline.I1 — Header parsing keeps the selected host grammar
- **scope:** `Jido.Action.Inline.parse_bound!/3, Jido.Action.Inline.parse_callback!/3`
- **must:** Bound headers return source AST without evaluating it. Callback headers receive params directly. Preserve supported patterns, clauses and guards. Reject improper bindings, ambiguous or unsupported options, invalid context bindings and malformed clause bodies with a source-aware CompileError.
- **kind:** functional
- **status:** active

### jido_action.inline.I2 — Generated Actions keep owner scope and normal Action behavior
- **scope:** `Jido.Action.Inline.compile!/4`
- **must:** Emit an ordinary Action with the owner lexical aliases, imports, attributes, private helpers and body source lines. Evaluate metadata, schemas, name and typed path once at the declaration site. Bind callback context separately from params. Remove only the requested declaration imports. Input and output validation use the normal Action boundary. A rejected static configuration must not replace an existing target.
- **kind:** functional
- **status:** active

### jido_action.inline.I3 — Typed identity and lookup are inert
- **scope:** `Jido.Action.Inline.target!/2, Jido.Action.Inline.compile!/4`
- **must:** Identity uses the owner and complete typed path independently of Action metadata. Reject invalid, duplicate or foreign paths before replacement. A false compile branch creates no target or index entry. Lookup after compilation returns only the Action target and performs no work or atom allocation for unknown paths. Compilation requires an open owner and lookup requires a completed owner.
- **kind:** functional
- **status:** active

### jido_action.inline.I4 — Owner hooks preserve declarations and reject conflicting functions
- **scope:** `Jido.Action.Inline.setup!/1`
- **must:** Repeated setup retains declarations. Early and late host hooks retain each target in either registration order, including a first late declaration. Reserved owner body and index functions reject user clauses and default-argument arities. Declaration errors retain source locations; body warnings and runtime stacktraces retain the body source.
- **kind:** functional
- **status:** active

### jido_action.inline.I5 — The Flow host retains ordinary Action meaning
- **scope:** `Jido.Action.Inline.Compiler`, `Jido.Action.Inline.Parser`, `Jido.Action.Inline.Owner`
- **must:** A Flow inline Step uses the shared owner and typed path and returns an ordinary Action target. Preserve body lexical scope, schemas, context and source locations. Host field, option, name, pattern and reference errors must occur before target emission; rejected edits preserve the loaded target and allow a corrected retry. Flow host slots keep their own named-Action and inline grammar, including rejection of clause bodies and unrelated nested Action declarations. Extracted targets can be used in every Action component slot.
- **kind:** functional
- **status:** active
