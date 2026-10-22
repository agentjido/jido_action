# Public API Reference

This reference documents `jido_action` `3.0.0-beta.21`. Execution uses Runic
`~> 0.1.0-alpha.12` from Hex. The contract register and Covenant obligations
record the evidence for the public promises.

For a first example, use [Getting Started](getting-started.livemd) or
[Build Your First Flow](build-your-first-flow.livemd). This document gives the
exact boundaries needed to write callers, tests, tools, and stored data.
The [contract review](https://github.com/agentjido/jido_action/blob/release/v3/guides/public-api-contract-review.md)
records 15 behavior obligations selected for verification and maps all 36
register entries and 42 original obligations. It also records defects,
documentation conflicts, and checks.

The terms have distinct meanings here:

- **Public:** supported module, generated API, DSL syntax, data value, or
  protocol integration used by callers.
- **Internal export:** callable implementation code with hidden documentation.
  Being exported does not make it an independent application API.
- **Observed behavior:** source behavior supported by cited tests or a stated
  probe. Missing tests and runtime limits are stated explicitly.
- **Inert:** does not run Action work. Trusted compile-time builders, schema
  callbacks, module loading, and metadata functions can still execute host
  code where the corresponding API permits them.

All function arguments in the tables are exact calling shapes. A default
argument supplies the shorter arities. Fields and option keys use their
literal Elixir spelling. Type names use `/arity`; they are not functions.
Unless a table says otherwise, callers must supply its stated input forms.
The package does not catch every possible malformed Elixir term at every
helper, macro, or direct dependency call.

Contents:

- [Actions and generated module APIs](#actions-and-generated-module-apis)
- [Shared validation rules](#shared-validation-rules)
- [Explicit Output values](#explicit-output-values)
- [Instruction calls and templates](#instruction-calls-and-templates)
- [Inline Action host API](#inline-action-host-api)
- [Action and Flow errors](#action-and-flow-errors)
- [Flow definitions and generated modules](#flow-definitions-and-generated-modules)
- [Expressions](#expressions-jido-expr)
- [Portable term validation](#portable-term-validation-jidoportableterm)
- [Stored Flow documents](#stored-flow-documents-jido-flow-codec)
- [Trusted stored identifiers](#trusted-stored-identifiers-jido-flow-registry)
- [Execution](#execution-jido-exec)
- [Telemetry](#telemetry-jido-exec-telemetry)
- [Runic integration and internal execution exports](#supported-runic-integration-and-internal-execution-exports)

## Actions and generated module APIs

`use Jido.Action, options` calls `Jido.Action.__using__/1`. It defines one
Action module. The module must supply `run(params, context)` (`run/2`). A
missing body is a compilation error. A direct call to `run/2` is an ordinary
Elixir call. It does not add validation, error conversion, a task, a timeout,
retry, telemetry, or effect delivery. Use Exec for those execution rules.

The macro accepts a keyword list or a plain map with atom keys. Computed
options are evaluated once at the declaration site. The supported keys are:

| Key | Accepted value and default |
| --- | --- |
| `id` | Stable authoring identifier. It defaults to the module name. |
| `vsn` | Positive authoring version. It defaults to `1`. |
| `name` | Required UTF-8 string. It must contain a non-space character and be at most 256 bytes. Punctuation and spaces are allowed. The value is kept; it is not trimmed or converted to an identifier. |
| `description` | A binary when supplied. Omission gives `nil`. Explicit `nil` is rejected for an Action. Invalid UTF-8 currently passes compilation but prevents `authoring_contract/0`. Flow configuration also accepts `nil` and checks UTF-8. |
| `schema` | `[]`, `nil`, or a static Zoi schema that can accept map data. Omission and `nil` become `[]`. |
| `output_schema` | The same configuration rules as `schema`; default `[]`. |

Unknown keys fail compilation. Configuration failure raises `CompileError`
with the declaration file and line. The common configuration implementation
converts keyword lists with `Map.new/1`; it does not reject duplicate Action
option keys. The last value wins. Do not infer the duplicate-option rule from
the Inline parser, which has a separate check.

A static schema can use a named MFA for refinements and transforms. It cannot
contain an anonymous function, a lazy schema, PID, port, reference, or improper
list tail anywhere in its data. It must also be escapable as module data.
Computed schema builders run once during compilation. The schema value is
fixed, but this does not freeze the code of an MFA that it calls later.

Map-compatible configuration includes Zoi map, object, struct, any,
discriminated union, literal-map, union with at least one map-compatible
member, intersection with all members map-compatible, and codec with
map-compatible input and output. A map default does not make a scalar schema
map-compatible. Internal schema classification can inspect lazy schemas, but
public static configuration rejects them first. Actual validation must still
produce a map.

### Generated functions and callbacks

Every generated Action has these functions. Flow modules use the same
metadata generator; their `"kind"` is `"flow"`.

| Entry point | Result or rule |
| --- | --- |
| `name/0` | The declared string. |
| `description/0` | The declared binary or `nil`. |
| `schema/0`, `output_schema/0` | The retained Zoi value or `[]`. |
| `authoring_contract/0` | A map with exactly `"id"`, `"vsn"`, `"kind"`, `"name"`, `"description"`, `"input_schema"`, and `"output_schema"`. |
| `validate_params(params)` (`/1`) | Runs optional preparation, then the retained input schema. Normal success is `{:ok, map}`. |
| `validate_output(output)` (`/1`) | Runs the retained output schema for a normal value, or validates an Output envelope. |
| `run(params, context)` (`/2`) | The user callback. Both arguments are maps at the normal Exec boundary. |
| `on_before_validate_params(params)` (`/1`, optional callback) | Receives raw input before the input schema. Return `{:ok, prepared}` or `{:error, reason}`. |

The behaviour also requires `validate_params/1` and `validate_output/1`.
A manually implemented behaviour must supply them. The macro generates them;
it does not mark them overridable. The preparation callback can change input
shape before Zoi parsing. Its error passes through a direct validator call.
Its raise, throw, exit, or invalid return is contained only when the caller
uses Exec. Prefer deterministic preparation because it can run again on retry.

Public types are `schema/0` (`Zoi.schema() | []`), `effects/0` (a list of opaque
requests), `effect_result/0` (`{:ok, map | Output.t(), effects}`), and
`result/0` (the callback forms below).

### Tool descriptions

`authoring_contract/0` gives descriptive data, not an executable tool and not a stored
Flow document. The two schema fields are `nil` for `[]`. Otherwise, Jido calls
`Zoi.to_json_schema/1`, then a strict Jason encode/decode round trip. The
successful value contains JSON string keys. Repeated calls return the
compile-time projection.

A Zoi schema can validate at runtime without a JSON Schema representation.
Projection errors are retained during compilation. `authoring_contract/0` then raises
`ArgumentError`, including the affected `:schema` or `:output_schema` when
schema projection fails. Invalid UTF-8 Action description has the same delayed
failure. Thus, successful Action compilation does not prove a usable tool
description. Runic port metadata falls back to an empty schema when the
projection raises `ArgumentError`; execution can still work.

JSON Schema does not replace the runtime validators. It does not fully express
preparation callbacks, all named refinements or transforms, or the Output
escape from normal output validation. Tool consumers must keep these limits.
There is evidence for JSON safety, missing projections, and retained schema
metadata. There is no evidence that every runtime validation rule can be
represented by a tool schema.

### Callback results at Exec

| Callback result | Exec meaning |
| --- | --- |
| `{:ok, map}` | Validate normal output and return `{:ok, validated}`. |
| `{:ok, %Jido.Action.Output{}}` | Validate the envelope; do not apply the normal output schema. |
| `{:ok, output, effects}` | `effects` must be a proper list. Validate output; retain requests in order. An empty list becomes two-element success. |
| `{:error, reason}` | Keep an exception reason as an exception. Convert other reasons to `ExecutionFailureError` with `action`, `phase: :run`, and the original `reason`. |
| `{:error, reason, ignored}` | Use the same error rule and discard the third value. The implementation does not require this discarded value to be a proper list. |
| `{:continue, input, target}` | Allowed only for a Dispatch expander. Input must resolve to a map. The target can be an Action, Flow module, Flow value, or bound Instruction. |
| `{:handoff, input, target}` | Allowed only for a root terminal Dispatch expander. Returns a validated successor Instruction and predecessor effects without running the successor. Every host must handle this result. Bound context and metadata are rejected. See [Dynamic Flows](dynamic-flows.md#terminal-handoff-to-a-new-turn). |
| Any other value | `ExecutionFailureError`, with `reason: :invalid_return` and `return: value`. |

An invalid success effects list gives `ExecutionFailureError`, with
`reason: :invalid_effects`, `action`, `phase: :run`, and `effects`. A continuation
in another position gives `reason: :unsupported_continuation` and preserves
its tuple in `return`. The final Dispatch target owns its output validation.
A continuation does not resume the expander. Error and output-validation
failure return no executable effect batch. Exec carries requests; it never
dispatches them. An Action body can still perform I/O itself.

Source: [Action](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/lib/jido_action.ex),
[authoring configuration](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/lib/jido_authoring/config.ex),
[generated API](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/lib/jido_authoring/compiler.ex),
[Action execution boundary](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/lib/jido_exec/node/action.ex).
Evidence: [Action tests](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/test/jido_action/action_test.exs),
[boundary validation tests](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/test/jido_exec/validation_contract_test.exs),
[Action node tests](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/test/jido_exec/node/action_test.exs),
[Action boundary properties](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/test/property/action/boundary_contract_test.exs).
The test named “rejects Action metadata that is not valid JSON” checks a
`authoring_contract/0` failure, not a compile-time rejection.

## Shared validation rules

Action and Flow input/output validation uses the same schema implementation.
`[]` skips field parsing, but these execution boundaries still require a map.
A successful scalar transform is rejected. Input preparation runs first, then
input parsing, Action work, and output parsing. At Exec, each validator must
return `{:ok, map}`; an output validator can also return a valid Output
envelope. The root and nested boundaries check these return shapes.

A direct object root changes Zoi's default `:strip` policy to `:preserve`.
Declared root fields are validated and unknown root fields stay. Explicit
`:error` remains strict. Typed unknown-key preservation still checks the
unknown keys and values. This rule does not recursively open nested or
wrapped schemas. They use their Zoi policy.

A direct struct schema validates the struct, including its refinements, then
normally returns a plain map. With no root transform, undeclared struct
defaults stay absent unless the input supplied them. With a root transform
that returns a struct, all final struct fields remain in the returned map.
An input-only field removed by a transform is not inserted again as a declared
field. For direct struct roots, separately retained unknown fields are merged
with the result, with validated values winning on a collision. A transform
that returns a scalar still fails at the Action or Flow map boundary.

String keys and scalar coercion require the corresponding Zoi coercion option.
Object `coerce: true` accepts string forms of declared atom keys and returns
the declared keys. Field `coerce: true` converts field values. Unknown string
keys remain strings in an open root. Jido does not add general string-to-atom
conversion for input.

Schema parse errors become `Jido.Action.Error.InvalidInputError`. Details
include caller boundary context and `errors`, a list of maps with `path`,
`message`, and `code`. Schema raises become a validation error with message
`"schema validation failed"`, `exception`, and the exception message in
`reason`. A schema throw or exit uses `failure_kind` and the inspected reason.
Unsupported schema values give `"Unsupported schema type"`. These schema
errors differ from an exception in a custom validation callback.

At Exec, a custom validator's `{:error, exception}` keeps the exception.
`{:error, reason}` becomes `InvalidInputError` with `action`, `phase`, and
`reason`. Any other result, including `{:ok, scalar}`, gives `InternalError`
with `reason: :invalid_validator_return` and the full `return`. A custom
validator raise, throw, or exit becomes `ExecutionFailureError`; it retains
`action`, `phase`, a stacktrace, and either `exception` or `kind` and `reason`.
A normal scalar Action output is rejected before the custom output validator
runs. An Output value is checked before and after a custom output validator.

The internal `open_validate_preserving_shape/3` mode keeps a validated struct
instead of projecting it to a map. It is used where the caller owns a
non-Action data shape. This helper is not a second public Action validation
API. Its direct scalar and lazy-schema tests do not establish public support
for scalar Action results or lazy Action configuration.

Source: [shared validation](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/lib/jido_action/validation.ex),
[Exec validation](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/lib/jido_exec/validation.ex).
Evidence: [schema tests](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/test/jido_action/validation_test.exs),
[open validation tests](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/test/jido_action/open_validation_contract_test.exs),
[execution boundary tests](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/test/jido_exec/validation_contract_test.exs),
[composed schema test](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/test/authoring/schema_pipeline_test.exs).
See [Schemas And Validation](schemas-validation.md) for examples of root,
strict-policy, and nested-schema behavior.

## Explicit Output values

`%Jido.Action.Output{kind: kind, value: value, meta: %{}}` has required `kind`
and `value` fields. Public types are `kind/0` (`:raw | :stream | :batch |
:opaque`) and `t/0`. Its public constructors are:

| Entry point | Value rule |
| --- | --- |
| `raw(value, opts \\ [])` (`/1`, `/2`) | Any term. |
| `opaque(value, opts \\ [])` (`/1`, `/2`) | Any term. |
| `batch(values, opts \\ [])` (`/1`, `/2`) | A proper list; no item schema. |
| `stream(enumerable, opts \\ [])` (`/1`, `/2`) | A value with an Enumerable implementation. A list must also be proper. |

Options must be a keyword list containing only `meta: map`; metadata defaults
to `%{}`. Constructors return the envelope directly. Invalid options, metadata,
kind/value combinations, or non-enumerables raise `ArgumentError` with
`"invalid action output envelope"`.

The value and metadata are retained. Checking a stream does not enumerate it.
A map can be an Enumerable; the `stream` kind is not limited to `%Stream{}`.
Output metadata is data and never acts as effects. The envelope bypasses the
Action or Flow normal output schema, but it does not bypass managed-value
portability. A valid local stream or opaque value can still be rejected by a
managed execution boundary.

`validate(value)` (`/1`) is exported with `@doc false`. It accepts only Output
structs, returns `{:ok, envelope}`, or gives `{:error, InvalidInputError}` with
the original value at `details.value`. Application callers should use the
constructors or the target's `validate_output/1`.

Source: [Output](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/lib/jido_action/output.ex).
Evidence: [Output tests](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/test/jido_action/output_test.exs),
[envelope boundary tests](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/test/jido_exec/validation_contract_test.exs).

## Instruction calls and templates

`%Jido.Instruction{}` has `kind`, `target`, `params`, `context`, and `metadata`.
The raw struct defaults are `nil`, `nil`, `%{}`, `%{}`, and `%{}` respectively.
`kind/0` is `:action | :flow`; `target/0` is an Action module, Flow module, or
`Jido.Flow.t()`. `params/0` is a raw term for internal binding; `context/0`
and `metadata/0` are maps. `t/0` describes a resolved call. `template_t/0`
describes a module target with empty params and context.

| Entry point | Input and result |
| --- | --- |
| `new(attrs)` (`/1`) | Atom-keyed map or keyword list with required `target`; returns `{:ok, instruction}` or `{:error, exception}`. |
| `new!(attrs)` (`/1`) | The same construction; returns the Instruction or raises the construction exception. |
| `resolve(target_or_instruction, params \\ %{}, context \\ %{})` (`/1`, `/2`, `/3`) | Normalizes, flattens, merges call-site data, and resolves the current target kind. It does not check every callback. |
| `validate(target_or_instruction)` (`/1`) | Resolves again, then checks required callbacks; returns `:ok` or `{:error, exception}`. It does not execute validation callbacks or Flow construction. |
| `template(kind, module, metadata \\ %{})` (`/2`, `/3`) | Returns an inert Instruction directly. It does not load the module. Invalid shape raises `ArgumentError`. |
| `bind(template, params, context, metadata \\ %{})` (`/3`, `/4`) | Checks the template and current target contract; returns `{:ok, instruction}` or `{:error, exception}`. |

For `new/1` and `resolve/1-3`, params, context, and constructor metadata accept
maps, keyword lists, or `nil`. Keywords become maps and `nil` becomes `%{}`.
Other values fail. There is no JSON constructor form; string keys are not
converted into constructor field keys. `target: nil` is invalid. Tuple call
shims are rejected. Removed atom keys `:id`, `:action`, `:flow`, and `:opts`
are rejected even if their value is empty; error `fields` are ordered as
`[:id, :action, :flow, :opts]`. Other unknown constructor keys are currently
ignored; the source does not implement general unknown-key rejection.

An existing Instruction can be the target. It is recursively flattened.
Outer params, context, and metadata replace equal inner keys. Call-site
params and context then replace equal stored keys. Each merge is shallow.
Call-site resolution has no metadata argument and retains the merged
metadata. Metadata does not select timeout, retry, Task Supervisor, or other
execution policy. A nested map at an overridden key is replaced as one value.

Module resolution calls `Code.ensure_compiled/1` and reads current behaviour
attributes on each call. A module must declare Action or Flow behaviour;
callback names alone are insufficient. Both behaviours together give
`ConfigurationError` with `reason: :ambiguous_behaviour`. Generated Flow
modules declare Action behaviour and expose an internal kind marker; they
still resolve as Flow. An old Instruction's retained kind is refreshed.
An explicit constructor kind or template kind that disagrees with the loaded
kind gives `ConfigurationError` with `declared`, `actual`, and
`reason: :target_kind_changed`.

Callback validation requires `run/2`, `validate_params/1`, and
`validate_output/1` for Action modules. It requires `flow/0`,
`validate_params/1`, and `validate_output/1` for Flow modules. A Flow behaviour
module does not require `run/2`. A runtime Flow value is accepted here without
full graph validation. Missing callbacks give `InvalidInputError` with
`target` and a reason such as `"missing run/2"`.

A template requires an allowed kind, a non-nil atom target, and map metadata.
It does not prove the atom is a module. Metadata is only shape-checked; the
constructor does not prove it is portable. `bind/3-4` rejects a template with
bound params or context. Context and runtime metadata must be maps, not
keywords or `nil`. Runtime metadata shallowly overrides template metadata.
Bound params remain exactly as supplied, including a keyword list, scalar,
or `nil`, until the execution path validates them. This support is useful
inside Flow execution; ordinary resolution of a stored Instruction still
requires map-compatible call data.

Construction errors use `InvalidInputError` with `reason: :invalid_attributes`,
`field: :target, reason: :missing`, `reason: :removed_instruction_fields`, or
the invalid call-data field plus `expected_format`. Binding errors identify
the field with `reason: :invalid_binding_data`. Invalid templates identify
`template` and one of `:invalid_template`, `:invalid_kind`, `:invalid_target`,
`:bound_params`, `:bound_context`, or `:invalid_metadata`. Unknown targets use
`ConfigurationError` with `target` and, where available, the module-load or
`:missing_behaviour` reason.

`normalize!(target_or_instruction, params \\ %{}, context \\ %{})` (`/1-3`)
is an internal exported helper marked `@doc false`.
It returns the same resolved value or raises. Invalid call-site params or
context raise `ArgumentError`; invalid stored fields and target errors raise
their structured exception. Use `resolve/1-3` as the application boundary
and `new!/1` for raising construction. This helper is not an additional
authoring API.

Instructions are call data, not a durable or JSON format. They carry module
atoms and can carry runtime context. A Flow data definition rejects bound
Instructions; Exec accepts them as direct targets and Dispatch continuation
targets. No Instruction function dispatches work.

Source: [Instruction](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/lib/jido_instruction.ex).
Evidence: [Instruction tests](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/test/jido_instruction/instruction_test.exs),
[target and reload tests](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/test/jido_instruction/target_test.exs),
[call properties](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/test/property/instruction/call_contract_test.exs),
[target properties](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/test/property/instruction/target_contract_test.exs).

## Inline Action host API

`Jido.Action.Inline` is a public compile-time host API. Its Parser, Compiler,
and Owner submodules are internal. A host installs owner hooks, parses a
slot, validates its own source expressions, emits declaration AST, then uses
the target AST. The API does not accept stored or runtime source code.

| Entry point | Contract |
| --- | --- |
| `use Jido.Action.Inline, options` (`__using__/1`) | Calls setup in the compiling owner. The current macro ignores its options. |
| `setup!(caller)` (`/1`) | Installs hooks in an open module, outside a function. Repeated setup preserves declarations and host hooks; returns `:ok`. |
| `parse_bound!(bindings_ast, options, caller)` (`/3`) | Returns `%Jido.Action.Inline{}` with source params AST and callback pattern. It does not expand or evaluate the source. |
| `parse_callback!(pattern_ast, options, caller)` (`/3`) | Returns a parsed value with `params_ast: nil`. It takes direct callback input. |
| `compile!(path_ast, parsed, caller, options \\ [])` (`/3`, `/4`) | Returns `%{declaration_ast: ast, target_ast: ast}`. Emit the declaration before the target expression. |
| `target!(owner, typed_path)` (`/2`) | Returns the ordinary Action module after owner compilation, or raises `ArgumentError`. It does not execute work or create new atoms during lookup. |

The parsed struct requires `mode`, `params_ast`, `pattern_ast`, `body_ast`,
`options`, and `context_ast`; `clauses` defaults to `nil`. Public types are
`mode/0`, `path/0`, `clause/0`, `t/0`, `compilation/0`, `remove_imports/0`,
`action_option/0`, and `compiler_option/0`. A clause is
`{parameter_pattern_ast, guard_ast_or_nil, body_ast}`. The struct contains
compile-time code, not a stable runtime or storage model.

Bound mode accepts `name <- source`, a proper list of named bindings, a sole
map-pattern binding, or `[]`. Named bindings build a params map keyed by the
binding names. A sole map binding uses the complete source. Empty bindings
build `%{}`. Names must be unique. Map and named bindings cannot mix. A bare
`_`, pins, binding-header guards, top-level struct patterns, executable map
keys, duplicate literal map keys, and map-update patterns are rejected.
Nested ordinary pattern syntax is checked by Elixir compilation.

Callback mode accepts a named variable or map pattern with no source binding.
For a body made only of `->` clauses, pass a `nil` header. Each clause has one
parameter pattern and can have a guard. A clause pattern can also be `_`.
Header patterns cannot accompany callback clause bodies. Expression and
clause bodies cannot mix. Bound clause bodies receive the resolved params
map. The Flow Inline Step host can impose a narrower grammar than this API.

The parser requires a keyword options list and rejects duplicate or unknown
keys. Allowed keys are `do` (required body), `name`, `description`, `schema`,
`output_schema`, and `context`. Schemas are explicit and default to `[]`;
they are not inferred from patterns. Validation and defaults occur before
pattern matching. `context` must be a named variable, not `_`, and cannot
collide with any parameter-pattern variable. It binds actual callback context
without adding an input key or schema field. Metadata and schema options keep
AST for evaluation at the declaration site.

Compiler options are `default_name` and `remove_imports`. Supply a default
metadata name unless the declaration has `name`. `remove_imports` defaults
to `[]` and contains `{module, [{name, arity}]}` entries. Each arity is a
non-negative integer. Only the specified declaration imports are removed;
other functions and macros remain in scope.

A typed path is a proper list with at least three `{atom_key, value}` entries.
It starts with `:host`, ends with `:role`, and has at least one middle segment.
Each value is a non-nil atom, string, or integer. The implementation does not
require a particular middle key or reject repeated segment keys. Complete
owner and path identity selects the target. Public Action name metadata is
separate. The path expression evaluates once when the emitted declaration
runs; a false compile-time branch creates no target.

Compilation retains owner aliases, imports, attributes, private helpers, and
body source locations. It emits a public internal owner function and an
ordinary Action wrapper. Deploy both owner and generated Action BEAM files.
Lookup is available only after owner compilation and returns no source
mapping. Extracting a target does not retain bound source expressions or
previous runtime context. Generated module names and body function atoms are
implementation details and are not code-version identifiers.

Invalid headers, options, paths, duplicate identities, reserved owner
functions, or calls outside an open owner raise `CompileError` at a useful
source location. Invalid metadata or static schemas fail before replacement
of an existing wrapper. Owner setup and early/late host hooks retain the
registered targets. Lookup with an unknown path, non-module owner, missing
owner index, or still-compiling owner raises `ArgumentError`.

Source: [Inline facade](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/lib/jido_action/inline.ex),
[parser](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/lib/jido_action/inline/parser.ex),
[compiler](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/lib/jido_action/inline/compiler.ex),
[owner hooks](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/lib/jido_action/inline/owner.ex).
Evidence: [Inline API tests](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/test/jido_action/inline_test.exs),
[public host tests](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/test/jido_action/inline_host_test.exs),
[build and release tests](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/test/jido_action/inline_host_build_test.exs),
[Flow host tests](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/test/jido_flow/dsl/inline_action_test.exs).
The Inline module's beta-version note is history, not an API rule.

## Action and Flow errors

The constructors below return exception structs directly. Each accepts
`message` plus optional `details`, default `%{}`. Plain maps and keyword lists
are retained as maps. Struct details, malformed lists, and other detail
containers are discarded to `%{}`. Constructor message arguments are typed
as strings, but the functions do not separately validate that type.

| Family and constructor (`/1`, `/2`) | Exception and owned fields | `to_map/1` type |
| --- | --- | --- |
| `Jido.Action.Error.validation_error(message, details \\ %{})` | `InvalidInputError`: `message`, `field: nil`, `value: nil`, `details`. Copies `field` and `value` from details. | `:validation_error` |
| `Jido.Action.Error.execution_error(message, details \\ %{})` | `ExecutionFailureError`: `message`, `details`. | `:execution_error` |
| `Jido.Action.Error.timeout_error(message, details \\ %{})` | `TimeoutError`: `message`, `timeout: nil`, `details`. Copies `timeout` from details. | `:timeout` |
| `Jido.Action.Error.config_error(message, details \\ %{})` | `ConfigurationError`: `message`, `details`. | `:configuration_error` |
| `Jido.Action.Error.internal_error(message, details \\ %{})` | `InternalError`: `message`, `details`. | `:internal_error` |
| `Jido.Flow.Error.validation_error(message, details \\ %{})` | `InvalidDefinitionError`: `message`, `details`. | `:flow_definition_error` |
| `Jido.Flow.Error.invalid_execution_error(message, details \\ %{})` | `InvalidExecutionError`: `message`, `details`. | `:flow_invalid_execution` |
| `Jido.Flow.Error.execution_error(message, details \\ %{})` | `ExecutionFailureError`: `message`, `flow: nil`, `details`. The constructor keeps `details.flow` but does not copy it to the struct's `flow` field. | `:flow_execution_error` |
| `Jido.Flow.Error.timeout_error(message, details \\ %{})` | `TimeoutError`: `message`, `flow: nil`, `timeout: nil`, `details`. Copies both fields from details. | `:flow_timeout` |
| `Jido.Flow.Error.internal_error(message, details \\ %{})` | `InternalError`: `message`, `details`. | `:flow_internal_error` |

Each concrete exception exports its `t/0` type and normal Exception functions
`exception/0-1` and `message/1`. Its `details` default is `%{}`. Default messages
are the corresponding source strings such as `"Invalid input"`,
`"Execution failed"`, `"Action timed out"`, `"Invalid Flow definition"`, and
`"Flow execution timed out"`. Match the exception module and detail keys.
Message text provides a diagnostic; see the conflict below before treating
all message text as stable matching data.

Both error families expose `details_input/0` (`map | keyword`) and
`error_map/0`. `to_map(error)` (`/1`) returns exactly
`%{type: atom, message: string, details: map, retryable?: boolean}`.
`retryable?(error)` (`/1`) returns a Boolean. Both functions unwrap
`{:error, reason}` and `{:error, reason, ignored}`.

For a concrete Action error, `to_map/1` preserves its message and detail values.
It adds non-nil `field`, `value`, or `timeout` from owned struct fields,
overriding equal detail keys. It omits the top-level Splode stacktrace. A
stacktrace already inside `details` remains. Unsupported values, including
foreign maps and foreign exception structs, map to `:execution_error`, empty
details, and no retry. A string remains its message; an atom becomes its atom
name; other values use `inspect/1`. Unsupported values cannot select their
own error type or retry policy.

Only concrete execution and timeout errors can request retry. Their direct
`details.retry` must be Boolean `true`. Missing, false, non-Boolean, nested,
and foreign retry hints do not request retry. Validation, configuration,
internal errors, and aggregate error groups are non-retryable. This function
classifies an error; actual attempts also depend on execution policy.

Flow `to_map/1` handles Flow leaves and delegates Action or foreign values to
the Action mapper. It inserts non-nil `flow` and `timeout` fields as applicable.
`Jido.Flow.Error.Invalid` is a documented ordered error group with
`errors: [Exception.t()]`. Its map type is `:flow_definition_error`, message
`"Invalid Flow"`, and details `%{errors: [mapped_error, ...]}` in the group's
current order. Internal Flow Execution and Internal groups use the same
mapping rule, with `:flow_execution_error` / `"Flow execution failed"` and
`:flow_internal_error` / `"Internal Flow error"`.

Only group members are recursively converted. A nested exception inside a
leaf `details` map remains the original value. The Flow module's broader
sentence about nested error conversion needs this limit. Error maps are not
a transport guarantee: PIDs, modules, tuples, stacktraces, non-UTF-8 binaries,
and other detail values remain unchanged. The package supplies no JSON
encoding protocol for its error structs.

### Splode integration

Errors use Splode classes. Action class priority is invalid, execution,
config, internal; Flow uses invalid, execution, internal. Flow can aggregate
Action errors without replacing their leaf modules. Splode aggregation can
deduplicate equal errors and choose a class; it is not a general promise to
retain duplicate diagnostic occurrences. Codec diagnostics create their
ordered group explicitly.

Inherited exported family helpers are `to_error(value, opts \\ [])` (`/1-2`),
`to_class(value, opts \\ [])` (`/1-2`), `splode_error?(value)` (`/1`) and
`splode_error?(value, family)` (`/2`), `set_path(error_or_errors, path)` (`/2`),
`unwrap!(result, opts \\ nil)` (`/1-2`), `from_json(module, map)` (`/2`), and
`traverse_errors(error_or_errors, function)` (`/2`). These are dependency
APIs inherited by the two families. They are not aliases of Jido `to_map/1`.

`to_error` keeps recognized leaf errors and converts other values through
Splode unknown errors. `to_class` groups recognized errors and applies the
class priority. Options include stacktrace and breadcrumb context.
`splode_error?` checks Splode membership. `set_path` prefixes Splode `path`
fields, including group members; it does not prefix Jido `details.path`.
`unwrap!` returns the value in `{:ok, value}` or `:ok`, and raises for an error
or invalid result shape. Its documented options select error conversion.
`traverse_errors` applies a unary callback to leaves and groups results by
Splode path. `from_json` delegates to the selected error module after Splode
key conversion; it is not the inverse of Jido `to_map/1` and is not a Jido
versioned storage format.

Splode also adds `splode`, `bread_crumbs`, `vars`, `path`, `stacktrace`, and
`class` fields to exception structs. Concrete modules export
`splode_error?/0`, `error_class?/0`, `keyword_list_options?/0`, and
`from_json/1`. Internal UnknownError modules have `message`, `error`, and
`details`; when `error` is non-nil, their message uses that value. Do not
create separate Covenant obligations for all inherited helpers. Existing
package tests establish class membership, invalid-class priority, leaf
preservation, and Jido map/retry rules. They do not establish every Splode
option, constructor field, transport input, or aggregate ordering rule.

Source: [Action errors](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/lib/jido_action/error.ex),
[Flow errors](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/lib/jido_flow/error.ex).
Evidence: [Action error tests](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/test/jido_action/error_test.exs),
[Flow error tests](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/test/jido_flow/error_test.exs),
[error properties](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/test/property/action/error_contract_test.exs),
[validator errors](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/test/jido_exec/validation_contract_test.exs).

### Error contract limits

- [Errors](errors.md) distinguishes validation and execution errors from native
  managed control reasons. `Exec.step(runner, unknown_id)` can return
  `{:error, :not_found}` unchanged.
- Contributor and caller rules use error types and documented reason/detail
  keys as the primary compatibility promise. Message text is for diagnostics;
  callers do not match on it.
- Flow `to_map/1` recursively maps group `errors`, not all nested detail data.
  Error map determinism does not mean portable JSON or removal of sensitive
  details.

## Internal exported Action and error helpers

An exported function can serve implementation code without being a supported
application API. These modules or functions use `@moduledoc false` or
`@doc false`. Preserve their behavior in normal tests when needed, but do not
make each export a separate public promise.

| Module | Internal exports reviewed |
| --- | --- |
| `Jido.Action` | `validate_params_for/2`, `validate_output_for/2`. |
| Jido.Action.Validation | `open_validate/3`, `open_validate_preserving_shape/3`, `zoi_schema?/1`, `map_schema?/1`. |
| `Jido.Action.Output` | `validate/1`. |
| Jido.Authoring.Compiler | `__using__/1` macro, `compile_json/2`, `json!/1`. Generated `__jido_authoring_kind__/0` is an internal target marker. |
| Jido.Authoring.Config | `validate_name/1-2`, `validate_config_schema/1-2`, `validate_map_schema/1-2`, `validate_static_data/1`, `prepare!/3`, `validate_flow/1`, `flow_name/1`, `description/1`, `schema/2`. |
| Jido.Authoring.Options | `validate!/4-5`, `allowed!/4-5`, `error!/2`. |
| Jido.Action.Inline.Parser | `bound!/3`, `callback!/3`, `options!/3-4`, `error!/3`. |
| Jido.Action.Inline.Compiler | `compile!/4`, `create!/4`, `create_action!/5`. Internal compiler options include host emission hooks; the public facade does not accept them. |
| Jido.Action.Inline.Owner | `ensure_compiling!/1`, `setup!/1`, `reserve_function!/2-3`, `__on_definition__/6`, `validate_path!/2`, `check_identity!/2`, `register!/3`, `__before_compile__/1` macro, `target!/2`. |
| Generated Inline modules/owners | `__jido_inline_action__/0`, `__jido_inline_actions__/0`, generated owner body functions. Their names and AST representation are implementation details. |
| `Jido.Instruction` | `validate_resolved/1`, `target_kind/1`, `validate_template/1`; `normalize!/1-3` is the internal raising helper noted above. |
| `Jido.Flow.Error` | `prefix_path/2` prefixes `details.path` if present. Internal Execution, Internal, and UnknownError groups support error conversion. |
| Jido.Flow.FieldError | Internal `%FieldError{errors: list}` and `new/1`. Construction moves each error's `details.path` to `details.source_path` and resets `details.path` to `[]`. It is not a public returned exception. |
| Jido.Action.Application | OTP `start/2`; starts `Jido.Exec.TaskSupervisor` with unlimited children under a one-for-one supervisor. |
| Both error families | Splode `__stacktrace_filters__/0` is an internal inherited export. |

Sources: [authoring compiler](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/lib/jido_authoring/compiler.ex),
[configuration](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/lib/jido_authoring/config.ex),
[options](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/lib/jido_authoring/options.ex),
[FieldError](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/lib/jido_flow/field_error.ex),
[application](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/lib/jido_action/application.ex).


## Flow definitions and generated modules

`Jido.Flow` owns the canonical graph and the module DSL. The supported public
modules in this area are `Jido.Flow`, `Jido.Flow.Ref`, `Jido.Flow.Value`, and
`Jido.Flow.Extension`. Codec, Registry, and Flow errors have separate sections.
The `Jido.Flow.DSL.*`, `Component`, `Definition`, `Graph`, `GraphValidation`,
`Identity`, and `FieldError` modules are implementation modules. The public DSL
syntax remains supported even though its implementation modules are internal.

### Flow functions, callbacks, and data

| Entry point | Input and result |
| --- | --- |
| `Jido.Flow.new(attrs)` | A plain map with atom field keys. Returns `{:ok, %Jido.Flow{}}` or `{:error, exception}`. It normalizes the data form, then checks graph rules. It does not load or run target modules. |
| `Jido.Flow.new!(attrs)` | Same input. Returns the Flow or raises the returned exception. |
| `Jido.Flow.validate(flow)` | Requires `%Jido.Flow{}` with exact canonical fields. Returns `{:ok, flow}` or `{:error, exception}`. It checks structure, schemas, values, reference scope, dependencies, and cycles. It does not repair non-canonical data or check loaded target contracts. |
| `Jido.Flow.dependencies(flow)` | Validates the canonical Flow, then returns `{:ok, %{name => %{needs: names, references: names, effective: names}}}`. `needs` keeps authored order. `references` is a sorted unique list. `effective` is the sorted unique union. |
| `Jido.Flow.explain(flow)` | Validates, then returns `{:ok, explanation}`. The map has `version: 1`, `kind: :flow`, `name`, `description`, `schema`, `output_schema`, `components`, `dependencies`, `output`, and `identity`. It has no execution state. |
| `Jido.Flow.semantic_identity(flow)` | Validates, then returns `{:ok, %{version: 1, algorithm: :sha256, digest: string, uuid: string}}`. See identity rules below. |
| `Jido.Flow.to_map(flow)` | Returns a map directly. Fields are `name`, `description`, `schema`, `output_schema`, `components`, and `output`. Components are a list in canonical order. References and expressions retain their struct tags. This function assumes a valid Flow; it does not validate and does not promise a structured error for malformed data. |
| `use Jido.Flow, options` | Calls `__using__/1` to install the module authoring API. |

The declared Flow callbacks are `flow/0`, `validate_params/1`, and
`validate_output/1`. `flow/0` returns `%Jido.Flow{}`. Input validation returns
`{:ok, map}` or `{:error, reason}`. Output validation returns `{:ok, map_or_output}`
or `{:error, reason}`; `map_or_output` includes `Jido.Action.Output`. Generated
modules also implement the shared `Jido.Action` behavior.

`%Jido.Flow{}` has `name`, `description`, `schema`, `output_schema`,
`components`, and `output`. Defaults in the struct are `description: nil`,
`schema: []`, `output_schema: []`, and `components: %{}`. A usable Flow still
needs a non-empty component graph and an explicit non-`nil` output. The data
constructor accepts a list of components and stores a map keyed by normalized
component names. Raw struct construction does not perform validation.

Public types are `t/0`, `dependency_info/0`, `source_location/0`, and
`source_map/0`. A source location can contain `file: string` and
`line: positive_integer`. A source map maps path lists to source locations.
Source locations are separate from canonical Flow data.

Except for `to_map/1`, the inspection functions above reject other subjects
with an `InvalidDefinitionError` whose message is `expected a Jido.Flow
artifact`. They do not accept a module directly. Call `Module.flow()` first.
`Jido.Exec.compile/2` adds executable target checks and returns a derived Runic
workflow. Inspection and compilation do not call Action `run/2`.

Source: [Flow facade](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/lib/jido_flow.ex),
[definition validation](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/lib/jido_flow/definition.ex). Evidence:
[canonical public subjects](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/test/jido_flow/canonical_authoring_test.exs),
[canonical structure](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/test/jido_flow/canonical_data_test.exs),
[inert inline inspection](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/test/jido_flow/dsl/inline_step_test.exs).

### Configuration and generated API

`use Jido.Flow` accepts `id`, `vsn`, `name`, `description`, `schema`,
`output_schema`, and `extensions`. `id` defaults to the module name, and
`vsn` defaults to `1`. `name` is required and must be a non-blank UTF-8 string of at
most 256 bytes. Validation does not trim or rewrite the accepted name.
`description` is a UTF-8 string or `nil`, with default `nil`. Both schemas
default to `[]`; explicit `nil` also normalizes to `[]` in authoring.
Schemas must use the shared static, map-shaped Zoi contract. Anonymous
functions, lazy schemas, process values, and improper lists within schemas
are rejected. Named MFA schema effects are allowed. Unknown configuration
keys are rejected.

`extensions` defaults to `[]`. It must be one static proper list of unique
modules. Each module must compile and use `Jido.Flow.Extension`. A duplicate
`extensions` option is rejected. This option is not part of a data definition
or a stored document.

A generated Flow module exposes:

| Function | Behavior |
| --- | --- |
| `name/0`, `description/0`, `schema/0`, `output_schema/0` | Return the declared shared module metadata and schemas. |
| `authoring_contract/0` | Returns JSON-safe string-keyed metadata with `"id"`, `"vsn"`, `"kind" => "flow"`, `"name"`, `"description"`, `"input_schema"`, and `"output_schema"`. An absent schema becomes `nil`. A schema without a JSON Schema representation makes this function raise `ArgumentError`; the module can still validate and execute. This is a module description, not a stored graph. |
| `validate_params/1`, `validate_output/1` | Use the shared Action validation rules. The input pre-validation callback is used when present. See the shared validation section for root key preservation, defaults, transformations, and envelopes. |
| `flow/0` | Returns the compile-time canonical Flow for the loaded module version. |
| `compiled/0` | Calls `Jido.Exec.compile!` with that Flow and its source map. Returns `Runic.Workflow.t()` or raises a compile error. It is a derived plan, not a cached runtime or durable execution. |
| `run(params, context)` | Calls `Jido.Exec.run(Module, params, context)` with default options. There are no generated `run/0` or `run/1` convenience forms. |
| `step_action(name)` | Takes a string or atom. Returns the Action module for an inline or explicit Action-backed Step. Raises `ArgumentError` for invalid names, missing names, and other component kinds, including Subflows. It does not carry the Step's params, needs, or metadata. It does not run work or create atoms. Call it after module compilation. |

A body edit can keep the same inline target name and semantic graph identity.
Deploy the owner module and generated Action modules together. The generated
`__jido_authoring_kind__/0` and `__jido_flow_source_map__/0` functions are internal
integration hooks.

Source: [module compiler](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/lib/jido_flow/dsl/module_compiler.ex),
[shared compiler](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/lib/jido_authoring/compiler.ex),
[shared configuration](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/lib/jido_authoring/config.ex). Evidence:
[generated functions](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/test/jido_flow/dsl/flow_test.exs),
[inline scope and lookup](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/test/jido_flow/dsl/inline_step_test.exs),
[extension validation](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/test/jido_flow/dsl/extension_test.exs).

### Module DSL forms

The `flow do ... end` block contains component declarations and one final
`output expression`. Output cannot be `nil`; it is never inferred from the
last component or from graph terminals. A Flow with only output is invalid.
Declaration source order does not create an execution dependency.

| Declaration | Forms and fields |
| --- | --- |
| `step/2` | `step name, action: Module, params: value, ...` or a field block. `action` and `params` are required in this DSL form. A loaded Flow target lowers to a Subflow; an Action target lowers to a Step. |
| `step/3`, `step/4` | Inline Step forms: name, one bindings argument, optional header options, and the body block. They produce an ordinary Action-backed Step. |
| `map/2` | Name plus keyword fields or a field block: `collection`, `action`, and `params` are required; `on_error` defaults to `:fail_fast`. |
| `reduce/2` | Name plus keyword fields or a field block: `collection`, `initial`, `action`, and `params` are required. |
| `choice/2` | Name and required field block. Contains at least one `option/2` and exactly one `otherwise/1`. |
| `option/2` | Name plus keyword fields or field block: required `condition`, `action`, and `params`. Option names are unique within the Choice. |
| `otherwise/1` | Keyword fields or field block: required `action` and `params`. It is a routing fallback, not an error recovery handler. |
| `iterate/2` | Name and required field block. Requires `state/2`, `action`, `params`, and one termination form. `update` defaults to `body_result()`. |
| `state/2` | Iterate declaration: schema as the first argument, plus required `initial` in keyword or block form. This declaration differs from the `state()` reference. |
| `dispatch/2` | Name plus keyword fields or field block: required `decision`, `expander`, and `params`. Both targets are Actions. |
| `output/1` | One value expression. No field block. Must be the final declaration. |

Every component accepts `needs` and `meta`. In the DSL, `needs` defaults to
`[]`, accepts `nil` as empty, accepts one string as a one-element list, and
accepts a proper list of strings. It rejects duplicate names. Data authoring
has different input shorthand, described below. DSL component names can be
strings or atoms and normalize to strings. Choice option names use the Spark
string field. `meta` defaults to `%{}` and must be portable data in a plain map.

Do not mix keyword fields with block fields in one declaration. Duplicate
options, unknown fields, and repeated block properties are rejected. Exact
failure classes differ: Jido uses `CompileError`, Spark can use
`Spark.Error.DslError`, and an improper DSL `needs` list currently raises a
`FunctionClauseError`. Do not promise one error class for all invalid DSL
syntax.

Iterate termination has two forms. `repeat n` uses `n` from 1 through 10,000
and forbids `max_iterations`. `while condition` requires `max_iterations` in
the same range and forbids `repeat`. The first lowers to completion when
`iteration_index() >= n`; the second lowers to `not condition`. The condition
is checked before each body call.

Inline bindings accept one named binding (`name <- source`), a list of named
bindings, a sole map pattern for the complete params value, or `[]` for no
input. Named bindings form atom-keyed params. Binding sources can contain
references and portable data, but cannot contain Flow operations. Put
calculations and pattern selection in the body. Top-level clause bodies are
rejected. The body retains owner aliases, imports, private helpers, module
attributes at the declaration, and normal Elixir scope. Inline settings are
`inline: [name:, description:, schema:, output_schema:, context:]`; `context`
binds the current callback context. `needs` and `meta` remain Step fields.
Only Step supports an inline body.

DSL reference syntax also accepts `input/0,1`, `context/0,1`, `result/1,2`,
`select/2`, `item/0,1`, `item_index/0`, `item_id/0`, `accumulator/0,1`,
`state/0,1`, `iteration_index/0`, and `body_result/0,1` in value fields.
`input()` means the complete input; the data helper uses `Ref.input([])`.
`value/1` wraps literal data, and `expr/1` is an optional expression wrapper.
These value-field forms are parsed syntax, not general runtime imports.
Ordinary maps and lists stay data; they do not become operations because
certain field names are present.

Source: [DSL schemas](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/lib/jido_flow/dsl/schema.ex),
[macros](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/lib/jido_flow/dsl/macros.ex),
[entity fields](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/lib/jido_flow/dsl/entity.ex),
[lowering](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/lib/jido_flow/dsl/lowerer.ex),
[value parser](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/lib/jido_flow/dsl/value_parser.ex),
[inline Step parser](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/lib/jido_flow/dsl/inline_step.ex). Evidence:
[DSL forms](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/test/jido_flow/dsl/flow_test.exs),
[needs forms and failures](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/test/jido_flow/dsl/needs_test.exs),
[inline forms](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/test/jido_flow/dsl/inline_step_test.exs),
[field block forms](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/test/jido_flow/dsl/wrapper_test.exs),
[guide-backed syntax](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/test/jido_flow/dsl/spark_surface_test.exs).

### Data definitions and canonical fields

`Jido.Flow.new/1` accepts root fields `name`, `description`, `schema`,
`output_schema`, `components`, and `output`. `name` must be a string.
`components` must be a non-empty proper list of plain maps. Each component
has `kind`, `name`, optional `needs`, and optional `meta`. Component names,
Choice option names, result names, and names in `needs` accept non-`nil`
atoms in data authoring and normalize them to strings. Names use the same
UTF-8, non-blank, 256-byte rule. Runtime input does not create atoms.

`needs` defaults to `[]`, and `meta` to `%{}`; explicit `nil` also selects
these defaults in data authoring. `needs` must be a proper list, with no
duplicates after name normalization. It does not accept the DSL's scalar
string shorthand. Call params default to `%{}`; explicit `nil` also becomes
`%{}`. Params can be any valid Flow expression at construction, but the
resolved call value must pass the target's input boundary at execution.
Required expression fields distinguish an absent key from an explicit `nil`: for
example, `collection: nil` can pass definition validation and fail at runtime.
The output field is the exception and always rejects `nil`. All unknown keys
are rejected, including internal `call` fields mixed into public data authoring.

| Data `kind` | Required fields beyond `kind` and `name` | Optional fields beyond common fields |
| --- | --- | --- |
| `:step` | `action: ActionModule` | `params` |
| `:subflow` | `flow: FlowModule` | `params` |
| `:choice` | `options`, `fallback` | None |
| `:map` | `collection`, `action` | `params`, `on_error: :fail_fast` or `:collect_errors` |
| `:reduce` | `collection`, `initial`, `action` | `params` |
| `:iterate` | `action`, `state`, `completion`, `max_iterations` | `params` |
| `:dispatch` | `decision`, `expander` | `params` for the decision |

A Choice needs a non-empty proper options list. Each option is a plain map
with `name`, `condition`, `action`, and optional `params`. The fallback is a
plain map with `action` and optional `params`. Conditions must be a Boolean,
`Jido.Flow.Ref`, or `Jido.Expr`; their resolved values must be Booleans.
An Iterate state is a plain map with required `initial` and `update`, and
optional `schema` defaulting to `[]`. `completion` is a stop condition, not a
while condition. `max_iterations` is required and must be 1 through 10,000.
The data form has no `repeat`, `while`, or implicit update shorthand.

Targets must be module atoms other than `nil`, `true`, or `false`.
Construction does not load them. Exec compilation checks the declared kind
and target contract. Only `:subflow` accepts a Flow in data authoring. Choice,
Map, Reduce, Iterate, and both static Dispatch positions require Actions.

The canonical component map stores names as keys and omits each inner
`name`. Step and Subflow become `kind: :call` with
`call: %{kind: :action | :flow, target: module, params: value}`. Choice retains
`options`, but each option has `name`, `condition`, and `call`; `fallback` is
one call record. Map, Reduce, and Iterate also use `call`. Dispatch stores a
full `decision` call and `expander: %{kind: :action, target: module}` without
params. Every canonical component includes `needs` and `meta`. Canonical
validation requires all fields and does not fill defaults or normalize names.

Do not pass a canonical component list to `Jido.Flow.new/1`. Its public input uses
`:step`, `:subflow`, and the compact fields above. `to_map/1` is an inspection
form, not a documented `new/1` round-trip or storage format.

Source: [definition rules](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/lib/jido_flow/definition.ex),
[component rules](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/lib/jido_flow/component.ex). Evidence:
[data authoring shape](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/test/jido_flow/data_authoring_shape_test.exs),
[boundary validation](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/test/jido_flow/boundary_validation_test.exs),
[unknown keys](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/test/jido_flow/unknown_key_validation_test.exs),
[canonical fields](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/test/jido_flow/canonical_data_test.exs),
[target kinds](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/test/jido_flow/executable_kind_test.exs).

### References and portable values

`Jido.Flow.Ref` has `source`, optional `component` defaulting to `nil`, and
`path` defaulting to `[]`. Its public types are `t/0`, `source/0`, `scope/0`,
and `path/0`. Supported constructors are:

| Functions | Source and use |
| --- | --- |
| `input(path)` | Flow input. There is no data-helper `input/0`. |
| `context()` / `context(path)` | Current runtime context. |
| `result(component)` / `result(component, path)` | Named component result; adds a dependency. |
| `select(ref, path)` | Appends a normalized path to a Ref after it validates the existing Ref. |
| `item()` / `item(path)` | Current Map or Reduce item. |
| `item_index()` | Zero-based Map or Reduce source index. |
| `item_id()` | Stable item identifier for its owner and source index. |
| `accumulator()` / `accumulator(path)` | Current Reduce accumulator. |
| `state()` / `state(path)` | Current Iterate state. |
| `iteration_index()` | Number of completed Iterate body calls. Starts at zero. |
| `body_result()` / `body_result(path)` | Last Iterate body output; initially `nil`. The update expression reads the just-completed body output. |

A `nil` path means `[]`; a scalar segment becomes a one-element list.
Segments are non-`nil` atoms, valid UTF-8 strings (including the empty
string), or non-negative integers. Paths must be proper lists. Index and
identifier sources require an empty path. Only `:result` has a component
name. Constructors generally defer path and scope validation to the Flow
boundary. `select/2` is an exception: it raises the existing Ref's structured
validation error. It does not separately validate the appended path before
returning; the complete Flow boundary does that.

Input, context, and result references are valid in every expression field.
Item, item index, and item ID are valid only in Map and Reduce params.
Accumulator is valid only in Reduce params. State, iteration index, and
body result are valid in Iterate params, update, and completion; they are
not valid in the initial state. Collection and initial fields cannot read
local iteration values.

Path resolution first tries the exact map key. For an atom segment only, a
missing atom key then tries the matching string key. A present `nil` or
`false` wins over the fallback. String segments never create or select atom
keys. Lists use zero-based integer indexing. Missing data is an execution
error, not an implicit `nil`: details include `ref_type`, `path`, `reason`,
`segment`, `resolved_path`, `value_type`, and `retry: false` as applicable.
Reasons include `:missing_key`, `:missing_index`, `:not_traversable`, and
`:source_not_available`. Result references also name the component in `node`.

`Jido.Flow.Value` exposes `validate_data(value)` and `validate_object(value)`.
Both return `:ok` or `{:error, InvalidDefinitionError}`. The latter requires a
plain map. Public types are `scalar/0`, `key/0`, `data/0`, `object/0`, and
`t/0`. Portable data contains numbers, valid UTF-8 strings, atoms, Booleans,
`nil`, proper lists, and plain maps. Map keys are valid UTF-8 strings,
non-negative integers, or non-`nil` atoms. Tuples, functions, process values,
and arbitrary structs are invalid definition data. A Flow value additionally
permits Ref and Expr structs. Literal maps remain distinct from those structs.

The complete Flow value tree has limits of 256 levels, 100,000 nodes,
1,048,576,000 binary bytes, and 1,048,576 integer bits. Expression subtrees
also obey the smaller `Jido.Expr` limits. These limits apply to definition
values; do not infer the same limits for immediate runtime input or output.

Source: [Ref](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/lib/jido_flow/ref.ex), [Value](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/lib/jido_flow/value.ex),
[runtime resolution](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/lib/jido_exec/value_resolver.ex). Evidence:
[Ref grammar](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/test/jido_flow/ref_test.exs),
[path behavior](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/test/jido_flow/ref_path_authoring_test.exs),
[value limits](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/test/jido_flow/value_test.exs),
[scope rules](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/test/jido_flow/component_validation_test.exs).

### Dependencies, inspection order, and identity

All result references in a component contribute static dependencies. This
includes references in unselected Choice options and fallback params,
collection expressions, initial values, state updates, and completion
conditions. `needs` adds control dependencies without passing a value.
Dependencies must name a top-level component, not a Choice option. Unknown
names, duplicate component names, self-cycles, and larger cycles are invalid.

Canonical component order uses the longest dependency-path level first,
then the component name. This is the order for inspection and component
effect collection. It is not a promise about task start or finish order.
Output can select an earlier component, but completion still waits for the
graph's terminals. A Dispatch is permitted only once, must be the sole graph
terminal, and requires output to be exactly its complete result reference
with an empty path. Its source declaration need not be last.

Identity version 1 includes the Flow name, input and output schemas,
canonical components, and output. It excludes the Flow description and
component metadata. It sorts `needs` because they represent a set, and
retains Choice option order because that order changes behavior. References
and literal maps with the same apparent fields remain distinct. Runtime
context, source locations, and execution progress are not identity inputs.
Target module atoms are identity inputs; deployed module code is not.

The digest is lowercase SHA-256 hex. The UUID uses the first 128 digest bits
with UUID version 8 and RFC variant bits. The implementation hashes
deterministic Erlang external-term data with the version tag. A golden test
checks one fixed digest across the supported OTP matrix. That fixture does
not prove that every possible Zoi schema or external-term shape is stable
across all OTP versions; do not claim a language-neutral graph identity format.

Definition field errors are checked before graph errors. Data component
field paths use list indexes; canonical component field paths use names.
Graph checks report missing output, duplicate names, unknown references,
then cycles or Dispatch constraints as applicable. Cycles report all blocked
components, which can include descendants of a cycle. Module compilation
attaches available source locations and normally raises at the owning
declaration. Do not treat internal diagnostic record layouts as public APIs.

Source: [graph validation](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/lib/jido_flow/graph_validation.ex),
[graph ordering](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/lib/jido_flow/graph.ex),
[identity](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/lib/jido_flow/identity.ex),
[source mapping](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/lib/jido_flow/dsl/source_map.ex). Evidence:
[dependency agreement and precedence](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/test/jido_flow/graph_validation_test.exs),
[graph order](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/test/jido_flow/graph_test.exs),
[identity and golden digest](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/test/jido_flow/graph_identity_test.exs),
[diagnostic paths](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/test/jido_flow/diagnostic_paths_test.exs),
[output source locations](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/test/jido_flow/dsl/output_source_test.exs).

### Component execution semantics

The table gives the supported component rules. Choice uses separate internal
identities for options and the default branch. An option named `"fallback"`
is valid and cannot collide with the default.

Runic owns readiness, task scheduling, and retry policy. The component nodes
do not provide a separate Jido scheduler or process handle. All Action calls
use Exec validation and return normalization. Nested Flows
validate their own input and output, receive the current runtime context,
and return their output at the parent component's position. They do not
expose a child's internal component names as parent result references.

| Component | Value, order, and failure behavior |
| --- | --- |
| Step | Returns the called Action output. A Subflow returns the child Flow output. |
| Choice | Tests conditions in authored order and stops at the first `true`. A condition error fails the Choice. No match selects the fallback. The fallback does not run after a selected Action fails. Only the selected path contributes effects. |
| Map with `:fail_fast` | Returns outputs in input order. An empty input returns `[]`. An item failure fails the execution; eligible Action errors can retry under Exec policy. Work already admitted can complete after a failure. |
| Map with `:collect_errors` | Returns one ordered `%{status: :ok, value: output}` or `%{status: :error, error: error_map}` per item. Failed Action results become data and do not retry as failed Runnables. Successful item effects remain in item order. A parameter-reference error also becomes error data, but lacks the Action's target, item index, and item ID details. |
| Reduce | Processes each item serially. `initial` becomes the first accumulator; each Action output replaces it. Empty input returns `initial`. The initial value must resolve to a plain map or `Jido.Action.Output`. Failure stops the loop. |
| Iterate | Validates the initial plain-map state, then tests completion. If complete, runs no body. Otherwise it resolves params, runs the body, resolves the replacement state, validates it, increments the completed count, and tests completion again. State is replaced, not merged. Returns `%{kind: :jido_flow_iterate_result, iterations: count, state: state, output: last_body_output}`; zero calls means `output: nil`. |
| Dispatch | Runs the decision Action, passes its complete result as expander params, then accepts a final expander result or `{:continue, input, target}`. Only the expander can continue. The selected Action or Flow is resolved and validated at runtime. It cannot create a general continuation loop at an ordinary Action position. |

Map and Reduce currently accept any value with an `Enumerable`
implementation and use `Enum.to_list/1`. Lists retain input order; other accepted Enumerables use
their own enumeration order. The caller must supply a finite collection.
An infinite Enumerable can prevent collection materialization from completing;
there is no separate public collection length bound in these nodes.

Item indexes are zero-based. Item IDs are lowercase SHA-256 strings derived
from the owner identity and source index. Equal input values at different
indexes have different IDs. Repeated runs of the same graph and position
keep the ID even when the item value changes. Nested owners have separate
IDs. The exact internal owner tuple is not a public storage format.

Iterate state validation uses the shared schema rules but requires both the
candidate and validated result to be plain maps. The completion value must
be Boolean. When completion remains false after `max_iterations`, execution
fails with phase `:iterate_exhaustion`, `max_iterations`,
`completed_iterations`, `state_revision`, `state`, and `retry: false`.
Initial and update failures use phases `:iterate_state_initial` and
`:iterate_state_update`. Condition failures use `:iterate_completion`.
Choice condition failures use `:choice_condition` and identify the option.

Effects keep multiplicity. Flow output collects successful component effects
in canonical component order; a nested Flow occupies its parent position.
Map uses item order, Reduce and Iterate use call order, and Dispatch places
decision effects before final expander or target effects. A failing execution
returns no executable effect list. Exec does not dispatch effect requests.
A `:collect_errors` Map can still be a successful execution with error data.

Source: [Choice selection](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/lib/jido_exec/node/choice/selector.ex),
[Map](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/lib/jido_exec/node/map.ex),
[Map collection](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/lib/jido_exec/node/map/collection.ex),
[Reduce and Iterate](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/lib/jido_exec/node/loop.ex),
[Dispatch](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/lib/jido_exec/node/dispatch.ex),
[Flow output](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/lib/jido_exec/node/output.ex),
[frame effect order](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/lib/jido_exec/frame.ex). Evidence:
[Choice](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/test/jido_exec/node/choice_test.exs),
[Map order, IDs, retries, and error data](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/test/jido_exec/node/map_test.exs),
[Reduce and ordered effects](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/test/jido_exec/node/loop_test.exs),
[loop error fields and Output initial values](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/test/jido_exec/error_paths_test.exs),
[authoring parity and serial state](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/test/authoring/components_test.exs),
[component behavior properties](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/test/property/flow/component_contract_test.exs),
[Dispatch paths and effects](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/test/jido_exec/node/dispatch_test.exs),
[Flow joins and nested boundaries](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/test/jido_exec/flow_execution_test.exs),
[boundary transformations](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/test/jido_exec/validation_contract_test.exs).

### Flow extensions

`use Jido.Flow.Extension` calls `__using__/1` with an empty keyword list.
Options raise `ArgumentError`. An extension exports authoring macros that
expand to normal Flow declarations. The installed marker callback is
`__jido_flow_extension__/0 :: true`; this is an internal validation marker.
Extensions can add source shorthand, but cannot add a canonical component
kind or runtime behavior. Data definitions and Codec never load extensions.
Extension macros execute at module compilation and must already be available.

Source: [extension contract](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/lib/jido_flow/extension.ex). Evidence:
[extension equivalence and source scope](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/test/jido_flow/dsl/extension_test.exs).

### Internal Flow exports

The following exports support package implementation. Public callers should
use the facade, constructors, DSL, and execution boundary above. Their presence
in BEAM does not make them separate compatibility promises.

| Internal owner | Exported implementation surface |
| --- | --- |
| `Jido.Flow` | `__before_compile__/1`, `__validate_config__/1`. |
| `Jido.Flow.Ref` | `sources/0`, `validate/1,2`, `normalize_path/1`. |
| `Jido.Flow.Value` | `normalize/1`, `validate/1,2`, `validate_key/1`, `prepare/1,2`, `condition/2`, `to_map/1`, `result_refs/1`. |
| Jido.Flow.Component | `maximum_iterations/0`, `fields/1`, `common_fields/0`, `option_fields/0`, `state_fields/0`, `diagnose/1,2`, `authoring/1`, `sequence/2`; internal call, target, and mode types. |
| Jido.Flow.Definition | `validate/1`, `validate_canonical/1`, `prepare_canonical/1`, `diagnose/1`, `diagnose_lowered/1`, `diagnose_body/3`, `validate_config/1`, `component/1`, `name/1`, `invalid_subject/1`, `needs/1`, `calls/1`, `values/1`, `reference_dependencies/1`, `effective_dependencies/1`, `to_definition/1`, `component_to_definition/1`, `to_map/1`; internal component and diagnostic types. |
| Jido.Flow.Graph and `GraphValidation` | `canonical_components/1`, `analyze/1`, and graph `validate/2`; internal analysis data. |
| Jido.Flow.Identity | `semantic_digest/1,2`, `for_flow/1`, `identity/1`. Public identity comes from `Jido.Flow.semantic_identity/1`. |
| Jido.Flow.FieldError | `new/1` and the internal errors wrapper struct. |
| Jido.Flow.DSL.ModuleCompiler | `__using__/1`, `register_step!/2`, `declaration_name!/2`, `reserve_function!/2`, `__before_compile__/1`, `before_compile/1`. |
| DSL parser and lowering | `Lowerer.lower/3`; `ValueParser.parse_fields/2`, `parse/1`, `parse_condition/1`; `InlineStep.parse!/3,4`, `defer!/1`, `emit!/1`, `declaration_imports/1`. |
| DSL source mapping | `SourceMap.put_entity/4`, `lookup/2`, `attach_issue/3`, `attach_error/2,3`, `attach_entity/2`. |
| DSL entity machinery | `Entity.__using__/1`, `build/2`, `__before_compile__/1`; entity modules' `entity/0` and parser structs; `Schema.sections/0`; Spark-generated section and field macros. |
| Jido.Flow.DSL.Extension and Jido.Flow.DSL | Internal Spark extension and DSL modules from `dsl/extension.ex`; generated Spark configuration, schema, section, and validation integration. Use `use Jido.Flow`, not these modules directly. |
| DSL macro support | `validate_options!/4`, `entity/6`, `source/1`, `compile_error!/2`. Public declaration syntax is listed above; direct use of the internal macro module names is not the authoring contract. |

The execution nodes below are also internal. Their structs and `t/0` types
store compiled runtime state; callers should not create or persist these
shapes as Flow definitions.

| Internal node | Exports in the implementation module |
| --- | --- |
| Jido.Exec.Node.Action | `new/1,2`, `run/3`, `execute/3,4`. |
| Jido.Exec.Node.Input | `new/1`, `resolve/3`, `run/3`. |
| Jido.Exec.Node.Output | `new/1`, `resolve/3`, `run/3`, `__runic_single_output__/0`, `__runic_batch_parent__/0`. |
| Jido.Exec.Node.Choice | `new/1`, `connect/3`, `condition/2`, `selected?/1`, `pass/1`, `run/3`. |
| Jido.Exec.Node.Choice.Branch and `Choice.Selector` | Each has `new/1`, `select/3`, and `run/3`. |
| Jido.Exec.Node.Map | `new/1`, `connect/3`, `pass/1`. |
| Jido.Exec.Node.Map.Collection | `new/1`, `resolve/3`, `run/3`. |
| Jido.Exec.Node.Loop | `new/1`, `connect/3`, `start/3`, `run_action/6`, `continue?/1`, `complete?/1`, `finish/3`, `condition/3`. |
| Jido.Exec.Node.Loop.Start | `new/1`, `run/3`. |
| Jido.Exec.Node.Dispatch | `new/1`, `connect/3`, `finished_condition/1,3`, `finished?/2`, `expansion/4`, `finish/1`, `target_component_key/1`. |
| Jido.Exec.Node.Dispatch.Finish | `new/2`, `finish/2`, `run/3`. |

Runic protocol implementations for these nodes expose the standard
`Runic.Component` functions `connectable?/2`, `connect/3`, `source/1`,
`hash/1`, `inputs/1`, and `outputs/1`, plus
`Runic.Identity.Projectable.identity_document/1`. Loop, Dispatch, and Output
also supply explicit `Runic.Workflow.Invokable` implementations with
`match_or_execute/1`, `invoke/3`, `prepare/3`, and `execute/2`. Nodes that use
`Runic.Workflow.SingleOutput` obtain that integration and marker exports from
Runic. Action has a `Runic.Transmutable` implementation with `transmute/1`,
`to_workflow/1`, and `to_component/1`. The supported caller boundary is the
compiled workflow and public Instruction integration, not these node
constructors, generated names, internal Fact tuples, or serializer code.

Source: [Action node](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/lib/jido_exec/node/action.ex),
[Input node](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/lib/jido_exec/node/input.ex),
[Output node](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/lib/jido_exec/node/output.ex),
[Choice node](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/lib/jido_exec/node/choice.ex),
[Choice branch](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/lib/jido_exec/node/choice/branch.ex),
[Loop start](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/lib/jido_exec/node/loop/start.ex),
[Dispatch finish](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/lib/jido_exec/node/dispatch/finish.ex).
The remaining node source links appear in the component section.

These helpers need normal tests for parser shape, compiler records, generated
names, graph mechanics, and source mapping. Covenant should instead establish
observable authoring equivalence, explicit output and dependency semantics,
component behavior, deferred effect order, and stable inspection meaning.
No single mixed-graph example establishes every component rule.

### Flow corrections and evidence limits

Dispatch must be the sole graph terminal, independent of source declaration
order. Map and Reduce accept finite Enumerables; lists retain input order and
other Enumerables use their own enumeration order. Reduce initial accepts a
plain map or Output envelope. `Ref.select/2` validates its existing source and
can raise; other reference constructors defer validation to the Flow boundary.

Choice options and the default now use distinct internal routes. An option
named `"fallback"` has regression coverage for matching and nonmatching
conditions, serial/concurrent execution, and Runic reconstruction.

Invalid DSL data can raise CompileError, Spark.Error.DslError, or a native
FunctionClauseError for malformed AST. Do not promise one universal error
family for arbitrary macro input. One golden identity fixture does not prove
universal cross-OTP schema stability or a cross-language identity format.
Authoring-equivalence tests establish supported graph meaning; the DSL keeps
its own shorthand and compile-time error boundary.


## Expressions: `Jido.Expr`

`Jido.Expr` is a closed expression language. It does not evaluate Elixir
source. A host can supply trusted reference callbacks. It cannot add an
operator through those callbacks. Expressions do not start processes, emit
telemetry, dispatch effects, or store state.

Source: [public facade](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/lib/jido_expr.ex),
[parser](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/lib/jido_expr/parser.ex), [runtime](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/lib/jido_expr/runtime.ex),
[limits](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/lib/jido_expr/limits.ex), and [error](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/lib/jido_expr/error.ex).
Evidence: [public API tests](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/test/jido_expr_test.exs),
[Elixir conformance](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/test/jido_expr/elixir_conformance_test.exs),
[boundary tests](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/test/jido_expr/survivor_contract_test.exs), and
[generated cases](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/test/property/expression/expression_contract_test.exs).
These files test different parts of the contract. One passing arithmetic
example does not establish the complete expression contract.

### Entry points and types

| Entry point | Input and result |
| --- | --- |
| `operations/0` | Returns the ordered list of supported `{operator, arity}` pairs given below. |
| `new(operator, operands)` | Returns `{:ok, %Jido.Expr{}}` or `{:error, %Jido.Expr.Error{}}`. Checks only the operator and operand arity. It does not check operand types, nested data, or resource limits. |
| `new!(operator, operands)` | Returns the expression or raises the construction error. |
| `parse(ast, options \\ [])` (`/1`, `/2`) | Takes quoted source or existing expression data. Returns `{:ok, expression}` or `{:error, error}`. The root must become a `Jido.Expr`. |
| `parse!(ast, options \\ [])` (`/1`, `/2`) | As `parse`, but returns the expression or calls `raise/1` with the returned error. A host error must be suitable for `raise/1` if this API is used. |
| `expr(ast)` macro (`/1`) | Expands trusted source into expression data. Accepts a variable pin `^variable`. Calls within a pin are rejected. Raises on parse failure. |
| `normalize(value, options \\ [])` (`/1`, `/2`) | Returns `{:ok, normalized_value}` or `{:error, error}`. Accepts an expression or a data tree. Does not evaluate operators. |
| `reduce(value, accumulator, reducer, options \\ [])` (`/3`, `/4`) | Returns `{:ok, final_accumulator}` or `{:error, error}`. Visits values before children. Accepts an expression or a data tree. |
| `validate(expression, options \\ [])` (`/1`, `/2`) | Returns `:ok` or `{:error, error}`. Requires an expression root. Checks the entire tree, including operands that evaluation can skip. |
| `evaluate(expression, options \\ [])` (`/1`, `/2`) | Returns `{:ok, value}` or `{:error, error}`. Requires an expression root. Resolves and evaluates only operands that are needed. |

`%Jido.Expr{operator: atom, operands: list}` requires both fields in a struct
literal. Type `t/0` describes this struct. `path/0` is a list of atoms,
integers, or strings. `limit_option/0`, `parse_option/0`, `parse_options/0`,
`validate_option/0`, `validate_options/0`, `normalize_option/0`,
`normalize_options/0`, `evaluate_option/0`, and `evaluate_options/0` describe
the option lists below. `reduce_result(accumulator)` is
`{:cont, accumulator} | {:halt, accumulator} | {:error, term}`.
`reducer(accumulator)` accepts either two or three arguments.

### Operations and source forms

The order of `operations/0` is:

`==/2`, `!=/2`, `</2`, `<=/2`, `>/2`, `>=/2`, `in/2`, `and/2`, `or/2`,
`not/1`, `+/2`, `-/2`, `-/1`, `*/2`, `//2` (the `/` operator with two
operands), `div/2`, `rem/2`, `min/2`, `max/2`, `abs/1`, `<>/2`.

| Operation | Rule |
| --- | --- |
| `==`, `!=` | Use Elixir non-strict equality. Thus `1 == 1.0` is true. |
| `<`, `<=`, `>`, `>=`, `min`, `max` | Use Elixir term order. Mixed types are accepted. For equal numeric values, `min` and `max` retain the native result value and type. |
| `in` | The right value must be a proper list. Membership uses strict `===`, so `1 in [1.0]` is false. |
| `and`, `or` | The left value must be a Boolean. Evaluation proceeds from left to right. Skip the right operand for `false and ...` and `true or ...`. Otherwise return the right value unchanged; it need not be Boolean. |
| `not` | Requires a Boolean and returns its inverse. |
| `+`, binary or unary `-`, `*`, `/`, `abs` | Require numbers. `/` returns native division results. Zero divisors and arithmetic failures return errors. |
| `div`, `rem` | Require integers. A zero divisor returns an error. |
| `<>` | Requires two binaries. No implicit conversion occurs. The result also consumes the binary budget. |

The parser keeps Elixir precedence and parentheses. It does not flatten
Boolean groups. Literal operands can contain atoms, numbers, binaries,
proper lists, and maps with atom, integer, or binary keys. Duplicate literal
map keys fail. The parser also accepts an `expr(...)` wrapper around the
same fixed grammar. It rejects tuples, ranges, assignments, remote calls,
aliases, unbound variables, unary `+`, `&&`, `||`, `===`, `!==`, and arbitrary
calls unless a trusted host explicitly accepts an unknown leaf.

`parse/2` rejects pins. Only the `expr/1` macro admits a pin of an existing
variable. The macro does not validate the runtime value inserted by that
pin. Validate the completed expression before relying on complete tree
validation. A Flow performs its own expression and reference validation.

### Callbacks, traversal, and limits

All options must be a keyword list. Unknown options, non-positive limits,
limits above the maximum, and unsupported callback arities return
`:invalid_options`. The APIs have no timeout option for trusted callbacks.
The caller must bound callback work.

| Option | APIs | Callback contract |
| --- | --- | --- |
| `leaf_parser:` | `parse`, `parse!` | Arity one. Receives unknown quoted syntax or a host struct. Returns `{:ok, host_value}`, `:error`, or `{:error, error}`. Fixed operators take precedence. A returned host value is inserted without a second parser walk. |
| `normalize_leaf:` | `normalize` | Arity one or two. Receives a host struct, then optionally its path. Returns `{:ok, replacement}` or `{:error, error}`. The replacement is walked and checked. The callback is not repeatedly applied to the same replacement root. |
| `validate_leaf:` | `validate`, `normalize` | Arity one or two. Receives a host struct, then optionally its path. Returns `:ok` or `{:error, error}`. Unknown structs fail without this callback. |
| `resolve:` | `evaluate` | Arity one or two. Receives a host struct, then optionally its path. Returns `{:ok, data}` or `{:error, error}`. Resolved data is never executed as a new expression. |
| reducer argument | `reduce` | Arity two: `(value, accumulator)`. Arity three: `(value, path, accumulator)`. Return `{:cont, accumulator}`, `{:halt, accumulator}`, or `{:error, error}`. Halt returns success without visiting children. |

The normal expression data walk accepts atoms, numbers, binaries, proper
lists, maps with atom/integer/binary keys, expression nodes, and host structs
when the API supports them. A reducer sees a host struct as one leaf. It
sees maps but does not receive a separate callback for map keys. Keys still
consume resources. Expression operand paths use `[:operands, index]`.
List paths use zero-based indexes. Map value paths use the key. Do not rely
on map traversal order; the implementation uses the Erlang map iterator.
List and operand traversal preserve their order.

The resolver has a broader data boundary. Resolved tuples, improper lists,
and structs remain inert and their children consume the budget. Other host
terms also remain inert in the runtime data walk. This is not a general
portability validator. Flow and managed execution add their own portable
data rules. Resolved map keys do not appear in expression failure paths;
list and tuple indexes remain visible. This prevents private runtime map
keys from leaking through a limit error.

| Limit option | Default | Maximum accepted option |
| --- | --- | --- |
| `max_depth:` | 64 | 1,048,576,000 |
| `max_nodes:` | 10,000 | 1,048,576,000 |
| `max_binary_bytes:` | 1,048,576 | 1,048,576,000 |
| `max_integer_bits:` | 4,096 | 1,048,576 |

The root is depth zero. The budgets apply to each call. Node and binary
budgets are cumulative. An integer magnitude must be less than
`2^max_integer_bits`. The sign does not add a bit. Evaluation counts visited
resolved data, produced results, and comparison work. Membership charges
comparison work for each examined item. For example, concatenating `"abc"`
and `"def"` requires 12 binary bytes: six input bytes and six result bytes.
Skipped operands consume no evaluation budget and do not call the resolver.
Validation still checks them. `new/2` has no options and applies none of
these tree limits.

### Expression errors

`%Jido.Expr.Error{reason: atom, operator: atom_or_nil, path: [], details: %{}}`
is an exception. `message/1` returns
`"invalid expression: REASON (OPERATOR) at PATH"`; the operator clause is
absent when it is nil. Generated Exception callbacks such as `exception/1`
are standard exception APIs. There is no expression `to_map/1` helper.

Current reasons are `:unknown_operator`, `:invalid_arity`,
`:expected_expression`, `:unsupported_syntax`, `:unsupported_value`,
`:invalid_map_key`, `:duplicate_key`, `:improper_list`, `:invalid_options`,
`:invalid_callback_return`, `:callback_failure`, `:invalid_reducer`,
`:invalid_reducer_return`, `:reducer_failure`, `:invalid_boolean_operand`,
`:invalid_membership_right_operand`, `:invalid_numeric_operands`,
`:invalid_binary_operands`, `:division_by_zero`, `:arithmetic_error`,
`:max_depth`, `:max_nodes`, `:max_binary_bytes`, and `:max_integer_bits`.
Type failures use `details.type` or `details.types`. Standard runtime errors
do not include operand values. A non-atom unknown operator is reported as
`operator: nil`.

Raises, throws, and exits from the parser/normalizer/validator/resolver
callbacks become `:callback_failure`. Invalid callback results become
`:invalid_callback_return`. A returned `Jido.Expr.Error` has the current
location prepended to its relative path. Other host errors pass through
unchanged. Reducer failures become `:reducer_failure`; a reducer's explicit
`{:error, error}` passes through unchanged, including its path. Host errors
can contain host data; the standard error privacy rule does not sanitize an
arbitrary error supplied by a callback.

For Flow use, construction failures become
`Jido.Flow.Error.InvalidDefinitionError` with message
`"invalid Flow expression"` and `details` keys `path`, `operator`, and
`reason`. Runtime Flow expression errors use the execution error boundary;
see the Flow and Exec sections. `Jido.Expr.validate/2` does not check Flow
reference scope or graph dependencies.

### Internal expression exports

The following exports have `@moduledoc false` and are implementation APIs:
Jido.Expr.Parser.syntax/0, `parse/2`, `expand!/1`;
Jido.Expr.Runtime.evaluate/2, `validate/2`, `normalize/2`, `reduce/4`;
Jido.Expr.Limits.new/2, `enter/4`, `enter/5`, `fail/2`, `fail/3`, `fail/4`,
`type/1`, `callback/3`, and `callback_error/2`.
Keep parser representation, map iterator details, and membership cost reuse
in normal tests. Keep closed grammar, operation results, host callback
boundaries, safe error locations, and resource limits in public evidence.

## Portable term validation: `Jido.PortableTerm`

`Jido.PortableTerm` is the shared strict boundary for Erlang terms that an
application stores or sends to another BEAM instance. It is not a JSON codec.
It does not change the value.

`validate/2` accepts a term and an atom or list root path. It returns `:ok` or
`{:error, path}`. `valid?/1` returns a Boolean. The validator checks map keys,
map values, tuples, and proper lists. It rejects PIDs, ports, references,
functions, improper lists, and non-byte-aligned bitstrings.

An error path has at most 20 segments. A binary or atom segment has at most
64 bytes. An integer map key stays in the path only when it is between
`-9_999_999_999_999_999` and `9_999_999_999_999_999`. Other map keys use a
bounded index marker. Map traversal has a deterministic term order.

`Jido.Exec` has a different managed execution policy. It uses an internal
mode of the same traversal. This mode permits improper lists and
non-byte-aligned bitstrings. It rejects only values that are local to one
runtime. Exec does not use the strict public `validate/2` function.

## Runtime authoring: `Jido.Authoring` and `Jido.Discovery`

`Jido.Discovery` scans configured application module lists and explicit
modules. It builds one immutable `Jido.Authoring.Registry` and stores it in
`:persistent_term`. Action and Flow modules publish a static manifest through
`__jido_authoring__/0`. Vocabulary modules can publish trusted schema and atom
entries.

`jido_action` starts one asynchronous Discovery child that scans all loaded
OTP applications. It starts once whether `jido_action` runs alone or as a
dependency of core `jido`. The Registry keeps
`:action` and `:flow` as separate kinds.
Document codec modules publish a type and `vsn` through
`__jido_authoring_codec__/0`.

Configure Discovery under the `:jido_action` application. Use an application
allowlist when editor or network input can select discovered definitions.
Discovery defines an inventory. It does not give permission to run a module.

| Entry point | Result |
| --- | --- |
| `Jido.Discovery.ready?/0` | Returns true after the first Registry build succeeds. A failed initial scan stays not ready, and `registry/0` raises with its reason. |
| `Jido.Discovery.refresh/1` | Builds and atomically installs a complete Registry. A failed build keeps the prior Registry. |
| `Jido.Discovery.registry/0` | Returns the current Registry. Raises when startup did not install one. |
| `Jido.Discovery.list/0`, `list/1` | Lists all entries or entries of one core kind. |
| `Jido.Discovery.get/2` | Gets one entry by its stable identifier and exact `vsn`. |
| `Jido.Discovery.get_by_target/2` | Gets one entry by its exact kind and trusted target. |
| `Jido.Authoring.encode/2` | Encodes a canonical authoring value with its discovered codec, or with the explicit `:codec` option. It checks the envelope, JSON compatibility, and byte limit. |
| `Jido.Authoring.encode_json/2` | Encodes a canonical authoring value as a bounded JSON string. |
| `Jido.Authoring.decode_json/2` | Parses a bounded JSON string, selects a codec by type and `vsn`, and returns a canonical struct or ordered issues. |
| `Jido.Authoring.decode/2` | Decodes JSON-compatible data through the same limits, Registry, and codec path. |

The JSON byte limit defaults to 8 MiB. It reads
`config :jido_action, Jido.Authoring, maximum_json_bytes: ...`. All four
storage entry points accept a per-call `:maximum_json_bytes` override.

Validation errors are ordered `%Jido.Authoring.Issue{}` values. Each issue has
a stable atom code, a source JSON path, a message, and JSON-compatible details.
The document envelope selects the decoder. Each owning package keeps control
of its body format and canonical validation.

Discovery and validation do not run Action work. They do not create atoms or
module names from document strings. The Registry must contain every code,
schema, and atom reference that a codec resolves.

## Stored Flow documents: `Jido.Authoring`

Authoring is the public stored-document boundary. It reads and writes decoded
JSON-compatible maps and JSON strings. It does not run Actions, load target
contracts, start processes, or emit telemetry. `Jido.Flow.to_map/1` output and
an Instruction are not stored documents.

Source: [public facade](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/lib/jido_authoring.ex),
[Flow codec](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/lib/jido_flow/codec.ex),
[writer](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/lib/jido_flow/codec/writer.ex),
[reader](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/lib/jido_flow/codec/reader.ex),
[value encoding](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/lib/jido_flow/codec/value.ex),
[limits](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/lib/jido_flow/codec/limits.ex), and
[path conversion](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/lib/jido_flow/codec/paths.ex).
Evidence: [Codec tests](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/test/jido_flow/codec_test.exs),
[generated Registry tests](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/test/jido_flow/generated_registry_test.exs), and
[storage properties](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/test/property/storage/codec_contract_test.exs).

### Entry points

| Entry point | Result and checks |
| --- | --- |
| `encode(value, opts \\ [])` | Returns `{:ok, document}` or `{:error, exception}`. It selects the codec from the Registry or the explicit `:codec` option. |
| `encode_json(value, opts \\ [])` | Encodes the same document with Jason and returns a JSON string. |
| `decode(document, opts \\ [])` | Returns `{:ok, canonical_value}` or ordered `Jido.Authoring.Issue` values. |
| `decode_json(json, opts \\ [])` | Applies the byte limit, parses with Jason, and decodes the document. |

Options are `:registry`, `:codec`, and `:maximum_json_bytes`. The default
Registry comes from `Jido.Discovery`. An explicit codec is useful with a
manually built Registry. There are no raising variants. Supply a Registry
built with `Jido.Authoring.Registry.new/1`; a manually forged Registry struct
is not fully revalidated.

### `vsn` 1 root and component records

The writer always emits all eight root fields. The reader accepts only the
listed fields. It requires `"type": "jido.flow"` and integer `"vsn": 1`.
Document `vsn` 1 is separate from semantic identity versions.

| Root field | Stored form and read rule |
| --- | --- |
| `type` | Required string `"jido.flow"`. |
| `vsn` | Required integer `1`. |
| `name` | Required valid Flow name: non-blank UTF-8 string, at most 256 bytes. |
| `description` | UTF-8 string or null. Defaults to nil when absent. |
| `schema` | Registry schema reference when present. Defaults to `[]` when absent. An explicit null is invalid. |
| `output_schema` | Same rule as `schema`. |
| `components` | Required non-empty list of the component records below. |
| `output` | Required non-nil encoded Flow value. |

Each component has `kind`, `name`, `needs`, and `meta`. The kind is a fixed
string. `name` follows the component name rules. `needs` is a list of unique
component names; omission or null becomes `[]` in lowered validation.
`meta` is an encoded portable data map; omission or null becomes `%{}`.
No references or expressions are permitted in metadata.

| Component `kind` | Additional fields |
| --- | --- |
| `"call"` | `call`: call record; kind may be `"action"` or `"flow"`. This is the stored form of a data Step or Subflow. |
| `"choice"` | `options`: non-empty ordered list of option records; `fallback`: Action call record. Each option has `name`, `condition`, and `call`. Option names must be unique. Conditions must decode to a Boolean, reference, or expression. |
| `"map"` | `collection`: encoded Flow value; `call`: Action call record; `on_error`: `"fail_fast"` or `"collect_errors"`. Omission defaults to `"fail_fast"`; explicit null fails. |
| `"reduce"` | `collection`, `initial`: encoded Flow values; `call`: Action call record. |
| `"iterate"` | `call`: Action call record; `state`: state record; `completion`: encoded Boolean/reference/expression; `max_iterations`: integer 1 through 10,000. State has `schema`, `initial`, and `update`. Its omitted schema defaults to `[]`; its present schema is a Registry reference. |
| `"dispatch"` | `decision`: Action call record; `expander`: Action target record without params. |

A call record has `kind`, `target`, and `params`. The target is a Registry
reference with `id` and `vsn` for the selected kind. Params use expression encoding. Missing or null
params become `%{}`. A target record has only `kind` and `target`. All other
component, option, state, call, and target fields listed above are required
unless a default is stated. Fields that hold values can contain nil where
the relevant Flow scope permits it. A missing field is distinct from an
explicit encoded nil in those fields. Unknown fields are errors.

The writer orders components by graph dependency and then by component
name. It preserves Choice option order and list order. A decoded component
list is normalized through the same lowered Flow validation used by other
authoring forms. Thus list order cannot create a dependency. Result
references and `needs` create dependencies. Validation also checks reference
scope, unique names, cycles, required output, and Dispatch placement.

### Tagged values

| Form | Fields and rule |
| --- | --- |
| Plain JSON scalar | UTF-8 string, number, Boolean, or null. |
| Plain JSON list | Each item uses the same encoding. Lists must be proper lists in the decoded Elixir data. |
| `{"$type": "atom", "id": ID, "vsn": VSN}` | Resolve the versioned reference as Registry kind `:atom`. Nil and Booleans normally use plain JSON scalar forms. |
| `{"$type": "map", "entries": [...]}` | Each entry is exactly `{"key": KEY, "value": VALUE}`. Keys use data encoding; values use the enclosing mode. Duplicate decoded keys fail. Valid keys are non-nil atoms, non-negative integers, or UTF-8 strings. |
| `{"$ref": {"source": SOURCE, "component": COMPONENT, "path": PATH}}` | `SOURCE` is one of the ten fixed strings below. `COMPONENT` is string or null, then checked for the source. `PATH` is a list of data-encoded segments, then checked by `Jido.Flow.Ref`. The component field may be omitted when nil is valid for the source. |
| `{"$expr": {"operator": OPERATOR, "operands": [...]}}` | `OPERATOR` is a fixed expression spelling. Operands use expression encoding. Complete expression validation checks arity, value forms, and budgets. |

Reference sources are `input`, `context`, `result`, `item`, `item_index`,
`item_id`, `accumulator`, `state`, `iteration_index`, and `body_result`.
Their scope and path rules remain the `Jido.Flow.Ref` rules.

Expression encoding accepts references and expressions inside lists and map
values. Data encoding, used for metadata, map keys, and reference paths,
rejects those tags. Literal maps always use the map tag, so a literal map
whose key is `"$expr"` is not treated as an operation. Tagged objects and
their inner records reject extra fields.

Map entries have a stable order by encoded key type and value: non-negative
integers, strings, registered atoms, then Booleans. With the same canonical
Flow and Registry, encoding produces equal stored maps. This is not a promise of
identical JSON byte order from every JSON library. The document contains
schema references, not schema values. A round trip requires the same Registry
bindings. Keep each referenced `vsn` available for the stored definition. The
document does not include Registry contents or deployed Action code. Inline
Steps store registered generated Action targets; they do not store an inline
body.

### Limits, errors, and diagnosis order

The decoder checks the entire supplied document before field decoding. The
encoder checks its finished document against the same limits:

- Maximum nesting depth: 100, with the document root at depth zero.
- Maximum entries in any one map or list: 10,000.
- Maximum data nodes in the complete document: 100,000. Maps, map keys, map
  values, lists, and scalar values consume nodes.
- Portable string fields must contain valid UTF-8.
- Canonical Flow and expression limits still apply after decoding.

The document limits do not impose a small total-byte limit. The separate
Flow data walk admits up to 1,048,576,000 binary bytes per value tree;
expression trees have smaller budgets. None of these limits bounds the
JSON parser or transport.

Safety limits are checked before the root envelope. Envelope failures are
terminal and report `type` before `vsn`. After a valid envelope, the
shared definition validator reports unknown fields, root fields, components
in input list order, then output. Component common fields precede
kind-specific fields. A missing output can be reported with other field
errors. Graph checks run only after valid field data. Unknown-reference
errors suppress the derived cycle error. Fix the current phase before
expecting later-phase errors.

Failures use `Jido.Flow.Error.InvalidDefinitionError` and the documented
Flow error types. Examples of matchable messages are
`"stored Flow document must be a map"`,
`"stored Flow document type must be jido.flow"`,
`"stored Flow document vsn must be 1"`,
`"stored Flow exceeds its nesting limit"`,
`"stored Flow collection exceeds its size limit"`,
`"stored Flow exceeds its total node limit"`,
`"stored Flow data must contain proper lists"`,
`"stored Flow data has an invalid tagged value"`, and
`"stored map contains a duplicate key"`.

Size errors include `maximum_depth`, `maximum_size`, or `maximum_nodes`.
Field and graph errors include stored JSON paths where applicable.
`Jido.Flow.Error.to_map/1` puts diagnosis leaves under `details.errors`.
Stored paths are captured during reading and used to translate semantic
error locations. This is a diagnostic result; it is not a second Flow or
an execution trace.

Encoding, decoding, Registry construction, and structural validation do not
establish that a target exports the Action or Flow contract. Use
`Jido.Exec.compile/1` or `/2` for that check. No stored document or semantic
identity is a code snapshot. Retain the application release and Registry
references needed to execute it.

## Portable authoring documents

`Jido.Authoring.Registry`, `Jido.Authoring.Value`, and
`Jido.Authoring.Document` are the shared storage foundation. A document owner
still owns its envelope, `vsn`, fields, reference kinds, and final semantic
validation. The internal Flow codec owns those rules for Flow documents.

### Trusted references: `Jido.Authoring.Registry`

`new/1` and `new!/1` validate bounded IDs, positive `vsn` values, and one
reference for each exact `{kind, value}` pair.
`resolve/3` reads an `{id, vsn}` reference of one required kind.
`reference/3` returns the same tuple form. Codecs convert between tuples and
JSON reference objects at their storage boundary.

The Registry is caller-owned data. It starts no process, loads no module, and
runs no Action. Stored strings do not create atoms or produce module names.
The Registry accepts any non-Boolean atom kind. `jido_action` defines
`:action`, `:flow`, `:schema`, and `:atom`. Packages above it can add kinds
without adding a second Registry.

Each ID is 1 through 255 ASCII bytes. It starts with a letter or digit. The
remaining characters are letters, digits, `.`, `_`, `/`, `:`, `@`, or `-`.
There can be at most 10,000 entries. The same `{kind, value}` cannot have two
references. Different `vsn` values can use the same ID.

### Portable values: `Jido.Authoring.Value`

`encode/2` and `decode/2` support these values:

- JSON scalar values with valid UTF-8 strings;
- proper lists;
- plain maps with valid UTF-8 string keys, non-negative integer keys, Boolean
  keys, or registered atom keys; and
- atoms that resolve through `:atom` Registry entries.

The value format rejects structs, tuples, processes, invalid UTF-8, improper
lists, duplicate decoded map keys, unsupported map keys, and an atom tag that
does not resolve to an atom. An accepted decoded value can be encoded again
with the same Registry.

The complete document boundary owns depth and collection limits. Portable
value conversion does not repeat those checks.

### Complete document limits: `Jido.Authoring.Document`

`check/1` limits one complete document to depth 100, 10,000 entries in one
collection, and 100,000 total nodes. It also rejects improper lists. It does
not validate the owner's envelope, fields, or portable value tags. Limit
errors include the active `maximum_depth`, `maximum_size`, or `maximum_nodes`
in their details.

A document owner must apply checks in this order:

1. Apply transport-byte and JSON-parser limits outside the codec.
2. Call `Document.check/1` on the complete decoded document.
3. Validate the document envelope, `vsn`, and exact fields.
4. Decode portable fields with `Value.decode/2` and resolve other typed IDs.
5. Run the owner's canonical semantic validation.

The shared low-level errors are `Jido.Authoring.Registry.Error`,
`Jido.Authoring.Value.Error`, and `Jido.Authoring.Document.Error`. They are
Splode invalid errors. `Jido.Authoring` returns its public invalid error during
encode and ordered issues during decode.

`Jido.Authoring.encode/2` requires an explicit Registry for a manual codec
override. Use application-owned IDs and an application version policy for
durable records.

Source: [Registry](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/lib/jido_authoring/registry.ex),
[portable values](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/lib/jido_authoring/value.ex), and
[document limits](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/lib/jido_authoring/document.ex).
Evidence: [shared authoring tests](https://github.com/agentjido/jido_action/tree/v3.0.0-beta.21/test/jido_authoring),
[Codec tests](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/test/jido_flow/codec_test.exs), and
[storage properties](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/test/property/storage/codec_contract_test.exs).

The generated-Registry helper, Flow codec, writer, reader, value adapter,
limit adapter, and path adapter are internal. They implement the public
`Jido.Authoring` contract.

### Storage and expression evidence limits

`Jido.Authoring`, `Jido.Authoring.Document`, `Jido.Authoring.Registry`, and
`Jido.Authoring.Value` are public. Flow codec modules are internal.
Contributor rules now make this clear.

`Jido.Expr.new/2` checks operator and arity. Parser leaves and macro pins
need complete validation at the host boundary. Flow construction performs
that validation. The expression guide now states the entry-point distinction.

Storage safety checks precede envelope checks. The storage guide now states
this order. Tests cover individual safety and envelope failures, not every
combination of simultaneous failures.

Codec tests exercise all component kinds, tagged values, unknown
references, malformed fields, limits, exact diagnostic paths, inline Action
registration, and equal Flow round trips. Registry tests establish inert
structural validation, not successful execution of every registered module.
Neither test suite establishes a code snapshot, an external JSON byte
canonicalization standard, cross-version generated-ID stability, or
Store acknowledgement. Those are separate concerns.

Recommended public evidence covers three storage behaviors: versioned
meaning-preserving deterministic map encoding; trusted typed reference resolution
without atom creation; and bounded rejection with useful diagnostics.
`STORE-002` and `SECURITY-001` describe the same trusted-reference boundary and
should share one evidence family. Keep internal path-index records,
helper field tables, and the current generated-ID sorting algorithm in
normal tests. For expressions, keep distinct evidence for operation
meaning/short-circuiting, source and host safety, and bounded walks. The
existing `EXPR-001` duplicates detailed expression I1; `EXPR-002` overlaps
I2 and I4 and must not be credited by a single constructor example.


## Execution: `Jido.Exec`

The supported target forms are an Action module, a Flow module, a
`%Jido.Flow{}`, and a `%Jido.Instruction{}`. Use `run/1-4` or `start/3-6` for
the complete Jido boundary. Compilation returns a native `Runic.Workflow`.
It does not run Action work. It can load modules, call metadata functions,
and call a Flow module's `flow/0`; those host functions must be inert.

Source: [Exec](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/lib/jido_exec.ex),
[compiler](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/lib/jido_exec/compiler.ex),
[Action node](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/lib/jido_exec/node/action.ex), and
[validation boundary](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/lib/jido_exec/validation.ex).
Evidence: [API tests](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/test/jido_exec/api_test.exs),
[compiler tests](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/test/jido_exec/compiler_test.exs), and
[boundary errors](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/test/jido_exec/error_paths_test.exs).

### Entry points and result types

| Signature | Result and limits |
| --- | --- |
| `compile(target, opts \\ [])` | `{:ok, %Runic.Workflow{}}` or `{:error, exception}`. Checks the resolved target callbacks, canonical graph, child targets, and recursive nested Flow cycles. It does not run Action work or input/output validation callbacks. |
| `compile!(target, opts \\ [])` | Workflow or raised compilation error. |
| `run(target, params \\ %{}, context \\ %{}, opts \\ [])` | Blocks until completion. Returns `{:ok, value}`, `{:ok, value, effects}`, `{:handoff, successor_instruction, effects}`, or `{:error, exception}`. An empty effect list uses the two-element success tuple for ordinary success. |
| `start(runner, execution_id, target, params \\ %{}, context \\ %{}, opts \\ [])` | `{:ok, worker_pid}` after worker start and input admission, or `{:error, exception}` for the handled failure paths. Work can start before the call returns. This is not a completion result. |
| `resume(runner, execution_id, context \\ %{}, opts \\ [])` | Restores through the Runner Store. Returns a worker PID or normalized error as for start. Supply context and policy again. |
| `step(runner, execution_id)` | `{:ok, workflow}`, `{:complete, workflow}`, or `{:error, reason}`. Reasons from Runic include `:busy`, `:automatic_dispatch`, and `:not_found`. These reasons are not exception structs. |
| `result(workflow)` | Projects a snapshot. Includes historical failure and uncertainty events. A missing result is `ExecutionFailureError`, message `"Exec produced no result"`. It does not prove that a snapshot is complete or saved. |
| `result(workflow, %Runic.Workflow.Execution{} = observation)` | Projects one input occurrence. Checks active work, failures, uncertainty, and stopped admission before selecting its result. |
| `result(runner, execution_id)` | Reads the occurrence admitted by `start`. The Runner argument is an atom. Missing lookup returns `{:error, :not_found}` unchanged. After resume, checks current active/ready work, then uses the snapshot fallback. |
| `effect_id(execution_id, activation_id, output_id, index)` | A `Runic.Identity` for a non-negative integer index. The index is zero-based. Invalid indices do not match the function clause. |

`task_supervisor/0` is the type `pid() | atom() | {:via, module(), term()}`.
`exec_result/0` permits the two success shapes, `{:handoff, Instruction.t(), [term()]}`,
and `{:error, term()}`;
`step_result/0` permits the two workflow shapes and `{:error, term()}`.
The managed specs accept a Runner module/name and an execution ID of any
term. A stable ID must meet Runic's identity and Store requirements. These
functions do not make arbitrary unavailable Runners safe: GenServer exits
and malformed direct API calls are not all caught by the facade.

Params and context accept maps, keyword lists, and `nil` (empty map). Call
site values shallow-merge over an Instruction. Instruction metadata does not
set policy. `run` validates its Task Supervisor and resolves the target,
then enters the immediate Flow span if applicable. In the execution task it
validates root Flow input, compiles, validates policy, executes, and projects
the observation. Thus invalid policy is not a promise that no schema hook or
metadata function has run. Action input validation occurs in its attempt.

### Compile options

Only `source_map`, `name`, and `id` are accepted. `name` and `id` apply only
to an Action root; a Flow rejects their presence, including a nil value.
`name` must be a string or non-nil atom. Jido does not validate the type of
`id`. The default Action node name is the Action name (or module string),
and its default ID is that name. `source_map` supplies diagnostic locations;
a generated Flow source map is used when this option is absent. Its value is
not fully checked as a public schema. Do not treat arbitrary malformed
source maps as supported input. Compile options must be a keyword list;
unknown keys produce `ConfigurationError` with `details.options`. Repeated
known compile keys are also rejected through this unknown-option check.

### Immediate execution options

| Option | Default | Accepted values |
| --- | --- | --- |
| `timeout` | `:infinity` | `:infinity` or integer milliseconds at least zero. Limit per runnable attempt, including internal Flow nodes. Zero permits no work time. There is no whole-call deadline. |
| `max_attempts` | `1` | Integer at least one, including the first attempt. Converted to Runic `max_retries = max_attempts - 1`. |
| `backoff` | `:none` | `:none`, `:linear`, `:exponential`, `:jitter`. Runic computes delay. |
| `base_delay_ms` | `0` | Non-negative integer. |
| `max_delay_ms` | `0` | Non-negative integer. Set both delay values for delayed retry. |
| `max_concurrency` | `1` | Positive integer. Values above one enable Runic asynchronous execution. |
| `task_supervisor` | `Jido.Exec.TaskSupervisor` | Live local PID, registered atom, or via tuple. Remote processes and duplicate entries are rejected. |

Unknown options and non-keyword options return `ConfigurationError`. Policy
errors use specific messages; not every error contains `option` and `value`.
Repeated policy keys are rejected by the unknown-option check because the
allowed list removes each key only once. Duplicate `task_supervisor` entries
have the dedicated `reason: :duplicate_option` error.

Runic gets `on_failure: :halt` and
`retry_if: {Jido.Action.Error, :retryable?, []}`. Only the allowed concrete
error types with `details.retry == true` can retry. A timeout or process
failure has no such hint by default. Retry can repeat external work.

For a zero-based failed attempt `n`, the reviewed Runic policy driver uses
these millisecond delays: `0` for `:none`,
`min(base_delay_ms * (n + 1), max_delay_ms)` for `:linear`, and
`min(base_delay_ms * 2^n, max_delay_ms)` for `:exponential`. For `:jitter`, it
draws a uniform integer from `1..max(base_delay_ms * 2^n, 1)`, then caps it at
`max_delay_ms`. It does not draw uniformly from an already capped range.
These rules come from the local Runic `lib/workflow/policy_driver.ex` at the
revision stated above. They remain dependency-owned behavior.

Failures stop new admission. Already admitted work can finish. Failure
selection uses causal depth, component name, and collection index. It does
not use completion order. Result and effect ordering is separate from task
start order. Nested and collection work uses the same scheduler policy;
Reduce and Iterate body work stays serial.

Evidence: [policy](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/test/jido_exec/runner/policy_test.exs),
[managed order and cancellation](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/test/jido_exec/runner/observation_test.exs),
[component properties](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/test/property/flow/component_contract_test.exs), and
[Runner fuzz cases](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/test/property/execution/runner_fuzz_test.exs).
A retry identity test does not establish every scheduler or backoff policy.

### Process ownership

The application starts `Jido.Exec.TaskSupervisor`. `run` creates an unlinked
task under the selected supervisor and gives it the caller's group leader.
A linked watcher monitors the caller and the execution task. Caller death
kills the execution task. Normal completion removes the watcher. Raises,
throws, exits, and a killed task return errors to a live caller instead of
exiting it. Task failure uses message `"Exec task exited"` and details
`phase: :execution_task, reason: reason`.

This cleanup covers the execution's owned task tree. It cannot close
arbitrary external resources or unlinked processes that an Action creates.
Actions must close those resources themselves.

Managed work belongs to the Runner and continues after the initiating caller
exits. The default executor uses the Runner Task Supervisor, including its
partitioned form, and the worker's group leader. Successful stop/cancel waits
for active tasks to die. A failed persistent stop keeps the same worker and
active tasks alive. Custom executors own their corresponding guarantees.

Evidence: [immediate task ownership](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/test/jido_exec/runner/immediate_task_test.exs)
and [managed task ownership](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/test/jido_exec/runner/task_ownership_test.exs).

### Managed options and portability

`start` and `resume` accept the five timeout/retry options above. They also
accept these worker options, passed to Runic:

| Option | Current default or rule |
| --- | --- |
| `max_concurrency` | `System.schedulers_online()` from Runic; positive integer. |
| `dispatch_mode` | `:automatic`; `:manual` enables `step`. |
| `checkpoint_strategy` | `:every_cycle`; also `:on_complete`, `:manual`, or `{:every_n, positive_integer}`. |
| `on_complete` | `nil`; Runic supports `fn id, workflow -> ... end` and `{module, function, extra_args}`. Jido does not validate this value. Completion does not prove persistence. |
| `executor`, `scheduler` | Runic defaults. Jido checks that a supplied atom module loads; it does not verify its whole behaviour contract. |
| `executor_opts`, `scheduler_opts`, `hooks`, `promise_opts` | Keyword lists. Their contents are owned by Runic. |

The default Runic executor runs work in supervised tasks under the Runner's
Task Supervisor. A custom executor defines how its work runs.

`task_supervisor` is not accepted here. Unknown options return a configuration
error. Repeated known managed keys also fail the unknown-option check.
Jido sets the scheduler policy to durable mode and supplies its own
runnable ordering. Runtime context is supplied through Runic's global
context. It is removed from the compiled root Instruction. It is not a
persisted secret store; an Action can still copy context into its output.

Before worker start, Jido rejects PIDs, ports, references, and functions in
params, metadata, or context, including map keys, nested containers, structs,
and improper list tails. Each successful Action result and its effects get
the same check in durable mode. The error is `ExecutionFailureError` with
`phase: :durability`, `reason: :non_portable_durable_value`, `type`, `path`,
and `retry: false`. Paths start with `:params`, `:context`, `:metadata`,
`:output`, or `:effects`. This is a process-local-value check, not JSON
validation or a guarantee that every custom struct has a Runic identity
codec. Runic can reject a value that passes this check.

If input admission fails after worker creation, Jido cancels the newly
created worker. A duplicate start does not cancel the existing worker. If
cleanup itself fails, its error is returned. See
[portable boundary tests](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/test/jido_exec/portable_test.exs),
[managed tests](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/test/jido_exec/runner/managed_test.exs), and
[portable traversal tests](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/test/jido_exec/boundary_rules_test.exs).

### Result scope, stepping, and recovery

An observation has its own input fact identity. `result(workflow, observation)`
selects only a result with that root ancestor. An active observation returns
`ExecutionFailureError` with `reason: :execution_active`. Stopped admission
without a more specific failure returns `reason: :admission_stopped`.
If the workflow has only another input's result, it returns
`reason: :foreign_execution`. All three use message
`"Exec execution is not complete"`, with `execution_id` and `retry: false`.

An uncertain executor outcome returns `ExecutionFailureError` with message
`"Runic execution outcome is uncertain"` and details
`phase: :execution_task, outcome: :uncertain, reason: original_reason,
retry: false`. It does not mean that no external work occurred. Historical
snapshot failure selection can differ from a fresh successful occurrence;
use the observation form when input scope matters.

`step` dispatches one scheduler unit. The default scheduler unit is one
Runnable; a custom scheduler can batch more work. `{:ok, workflow}` can be
returned while that unit is active. `:busy` means wait for completion before
another step. When admission stops, active units must drain before step
returns `{:complete, workflow}`. This tuple can mean success, failure, or
uncertainty. It can retain ready work that will not be admitted. Read
`result(runner, id)` to determine the outcome.

Runic observations are local to the worker process and are not restored.
After resume, the Runner form checks `active_units` and runnable work under
open admission before projecting the restored snapshot. That fallback
includes historical failures and uncertainty; it cannot recreate all prior
input observations.

Use Runic `checkpoint/2`, `stop/3`, `cancel/2`, `continue/2`,
`get_workflow/2`, and `persistence_status/2` for lifecycle and persistence.
Jido has no additional checkpoint format or async handle. A successful
checkpoint means the configured Store acknowledged the write. Store durability
depends on its adapter; default ETS storage does not survive VM loss. In the
reviewed Runic source, persistence status is
`{:ok, %{status: :saved | :pending | {:error, {:persistence_failed, reason}},
event_cursor: cursor, pending_events: count}}` or `{:error, :not_found}`.
The query does not retry persistence. A result and `on_complete` can occur
while writes remain pending or failed. Do not synchronously call the worker
again from a worker hook; forward a message to an observer instead.

Recovery keeps completed work present in acknowledged stored progress.
A crash after external work but before the checkpoint can cause repeated
work. Supply context, retry policy, executor, scheduler, and manual dispatch
settings again as needed. The code does not prove that supplied context is
the same as before. There is no exactly-once promise or rollback of Action
side effects. Effect requests defer delivery to the host; they do not make
the host's delivery atomic.

Evidence: [input observations](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/test/jido_exec/observation_test.exs),
[live and restored observations](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/test/jido_exec/runner/observation_test.exs),
[stepwise](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/test/jido_exec/runner/stepwise_test.exs),
[recovery](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/test/jido_exec/runner/durability_test.exs), and
[managed context](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/test/jido_exec/runner/managed_test.exs).
The Store separation test changes observation persistence data directly.
The failed-stop test uses a failing Store. These are distinct evidence; neither
alone establishes a full Store failure and recovery matrix.

### Effects and identity

Effects are ordered proper lists of requests. Exec does not dispatch them.
Duplicates are retained. Only successful output returns an effect batch;
callback failure, invalid output, timeout, cancellation, and uncertain work
must not be treated as a successful effect batch. A successful Map with
`collect_errors` can include error values and still return effects from its
successful items.

Flow effects follow canonical dependency order, with component name as the
stable tie-breaker. Nested effects occupy the parent component's position.
Map, Reduce, and Iterate effects follow item or iteration order. Selection of
one output does not remove effects from other successful executed components.

`effect_id/4` hashes a version-1 document through
`Runic.Identity.digest(:event_data, ...)`. Its fields are
`kind: :jido_effect`, `version: 1`, `execution_id`, `activation_id`,
`output_id`, and `index`. No attempt ID is included. Equal supplied identity
inputs produce the same logical effect ID across retries. A changed output
identity can change it. The normal `run` tuple does not include Runic IDs;
obtain these from the completed Runic event/result when using this helper.
Do not promise cross-version identity-byte stability beyond the declared
format and the Runic identity contract.

Evidence: [effects guide tests](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/test/examples/action_effects_test.exs),
[effect ordering](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/test/property/flow/component_contract_test.exs), and
[retry/effect identity](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/test/jido_exec/runner/policy_test.exs).

## Telemetry: `Jido.Exec.Telemetry`

`event_names/0 :: [[atom()]]` is the supported function. It returns Action
start, stop, exception, then Flow start, stop, exception in that order:
`[:jido, :action, :start | :stop | :exception]` and
`[:jido, :flow, :start | :stop | :exception]` denote six separate lists.
The public type `kind/0` is `:action | :flow`.

Action spans enclose each attempt, including input and output validation.
An immediate Flow span encloses its complete supervised call after target
resolution. A managed execution has Action spans and Runic runtime events,
but no Jido Flow span. Nested Flows do not start separate immediate Flow spans.
Telemetry handlers run synchronously in the emitting process.

| Event fields | Shape |
| --- | --- |
| Start measurements | `monotonic_time`, `system_time` in native time units. |
| Stop measurements | `monotonic_time`, `duration` in native time units. |
| Action metadata | `action`, `action_name`, `node_name`, `runnable_id`, `activation_id`, `attempt_id`, zero-based `attempt`. |
| Flow component metadata | When available: `component`, `node_path`, `component_kind` (`:step`, `:choice`, `:map`, `:reduce`, `:iterate`, `:dispatch`), `dispatch_phase` (`:decision`, `:expander`, `:target`). |
| Flow metadata | `kind: :flow`, `flow` name, and `target` only for a module target. |
| Successful stop additions | `outcome: :ok`, `effect_count`. Counts the span's returned list; a Flow component can carry effects in its frame, so its Action count need not equal the final Flow effect count. |
| Failed stop additions | `outcome: :error`, `error_type`, `retryable?`. |
| Escaped exception | Standard `:telemetry.span/3` exception measurements and `kind`, `reason`, `stacktrace` metadata. This path can contain original failure data. The bounded-data promise applies to start and stop. |

Normal caught callback failures produce stop events with an error outcome,
not exception events. A timeout or process death can kill the emitter before
its stop event. Do not require one Action stop per start. A live immediate
Flow caller can still emit its outer stop when the execution task dies.
Caller death also prevents a guaranteed outer stop. Use the returned error
or Runner outcome to determine termination.

Source: [telemetry](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/lib/jido_exec/telemetry.ex).
Evidence: [telemetry tests](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/test/jido_exec/telemetry_test.exs) and
[Runner telemetry fuzz](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/test/property/execution/runner_fuzz_test.exs).
The ordinary telemetry test proves outer Flow stop on task kill, not Action
stop on timeout. Start/stop omit params, context, output, effects, and full
error values; they retain semantic identifiers supplied by trusted code.

## Supported Runic integration and internal execution exports

`Runic.Transmutable` is implemented for `Jido.Instruction`:
`transmute/1` and `to_workflow/1` return a workflow. `to_component/1` accepts
an Action Instruction and returns a native component. A Flow Instruction
raises `ArgumentError` from `to_component/1`, because it needs a workflow.
These protocol calls require a currently resolved Instruction kind. They
select a branch from the retained kind before compilation. The Action branch
does not refresh a stale kind as `Exec` resolution does; `kind: nil` has no
matching protocol clause. Resolve an Instruction again before direct use.
The Action component supports public Runic `Component`, `Transmutable`,
`Identity.Projectable`, and `Workflow.SingleOutput` integration. Its input
and output ports expose descriptive JSON schemas. An omitted declared schema
produces `nil`. Missing description functions/keys or an `ArgumentError`
during projection use `%{}`. Schema descriptions do not replace Jido validators.

Use Runic protocol functions on values returned by Jido. Do not construct or
mutate private node structs. Direct Runic execution bypasses parts of the
facade, including root Flow input preparation and immediate task ownership.
The caller must supply those boundaries when using Runic directly. Tests
use direct Runic calls to check integration, result observations, and build-log
reconstruction. Use `Exec.run` or `Exec.start` for normal application code.

Source: [Instruction protocol](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/lib/jido_exec/runic/instruction.ex) and
[Action protocols](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/lib/jido_exec/node/action.ex).
Evidence: [native Action tests](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/test/jido_exec/node/action_test.exs),
[rebuild tests](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/test/jido_exec/rebuild_test.exs), and
[observation tests](https://github.com/agentjido/jido_action/blob/v3.0.0-beta.21/test/jido_exec/observation_test.exs).

The following exports are implementation entry points, not new application
APIs. Their source files use `@moduledoc false` or `@doc false`:

| Module | Exported implementation work |
| --- | --- |
| Jido.Action.Application | `start/2`; starts the package Task Supervisor. |
| Jido.Exec.Compiler | `compile/1,2`, `compile!/1,2`, `compile_nested!/2`, `validate/1`, `validate_targets/1`. Use the Exec/Flow facade. |
| Jido.Exec.Validation | `input/2,3`, `output/2`, `schema/3,4`, `output_schema/3`, `callback/4`, `apply/4`. |
| Jido.Exec.Portable | `validate/2`; execution error mapping for process-local term validation. |
| Jido.Exec.Source | `attach/2,3`; adds diagnostic location details. |
| Jido.Exec.ValueResolver | `condition/4`, `resolve/2`; resolves references and expressions. |
| Jido.Exec.Frame | `new/1`, `nest/2`, `merge/1`, `put_result/4`, `item_id/2`, `resolver_state/2`, `effects/2`, `fetch_result/2`, `effects_for/2`, `complete_nested/4`. Frame tuple tags and fields are not stored Flow format. |
| Jido.Exec.Fact and `.LocalValue` | `local_root/1`, `child/2`, `child_options/3`, `result/3,4`, `value/1`, `unwrap/1`, `local_value/1`; local term wrapper and identity projection. |
| `Jido.Exec.Telemetry` helpers | `span/3`, `action_metadata/2`, `flow_metadata/1`, `result_metadata/2`. |
| Jido.Exec.Node.Action | `new/1,2`, `run/3`, `execute/3,4`, plus generated Runic hooks. |
| Other `Jido.Exec.Node.*` modules | Constructors, connectors, selectors, loop/dispatch helpers, protocol functions, and runtime structs listed with the Flow component review. |

The native one-node Action layout, generated node names, component hashes,
frame layout, local identity wrapping, fact size, and parser/compiler records
need normal integration or performance tests. They do not each need a
Covenant promise. The returned workflow's supported Runic protocol behavior
remains part of integration compatibility.
