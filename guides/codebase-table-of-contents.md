# Jido Action – Codebase Table of Contents  

*(Generated 2025-09-04)*  

---

## 1. Repository Layout  

```
lib/
├─ jido_action/           # Core framework (behaviours, runtime, exec engine)
│  ├─ exec/               # Execution pipeline helpers (retry, async, etc.)
│  ├─ application.ex      # OTP application bootstrap
│  ├─ tool.ex             # AI-tool serializer
│  ├─ error.ex            # Shared error struct/helpers
│  └─ util.ex             # Misc helpers (name validation, etc.)
├─ jido_action.ex         # `Jido.Action` behaviour & macro
├─ jido_instruction.ex    # `Jido.Instruction` – action wrapper
├─ jido_plan.ex           # `Jido.Plan` – DAG / workflow builder
└─ jido_tools/            # 25 + pre-built tools (Actions)
   ├─ basic.ex
   ├─ arithmetic.ex
   ├─ files.ex
   ├─ weather/…
   ├─ github/…
   ├─ simplebot.ex
   ├─ workflow.ex
   ├─ action_plan.ex
   └─ req.ex
test/ …                   # Extensive unit / integration coverage
```

---

## 2. Core Framework Modules  

| Module | Purpose | Key Public APIs | File |
|--------|---------|-----------------|------|
| **Jido.Action** | Compile-time macro & behaviour for defining validated, composable actions. Handles param/output schemas, metadata, AI-tool generation. | `run/2` (callback), `validate_params/1`, `validate_output/1`, `to_tool/0` | `lib/jido_action.ex` |
| **Jido.Exec** | Runtime execution engine: validation, retries, timeouts, telemetry, async, cancellation. | `run/3‒4`, `run_async/4`, `await/2`, `chain/2` | `lib/jido_action/exec.ex` |
| &nbsp;&nbsp;└─ **Exec.* sub-modules** | Isolated concerns used internally by `Exec`. |  | `lib/jido_action/exec/` |
| &nbsp;&nbsp;&nbsp;&nbsp;• Retry | Exponential back-off logic | `with_retry/4` | `exec/retry.ex` |
| &nbsp;&nbsp;&nbsp;&nbsp;• Async | Task supervision / await helpers | `run_async/4`, `await/2` | `exec/async.ex` |
| &nbsp;&nbsp;&nbsp;&nbsp;• Validator | Delegated parameter / output validation |  | `exec/validator.ex` |
| &nbsp;&nbsp;&nbsp;&nbsp;• Chain | Sequential execution of action lists | `run_chain/3` | `exec/chain.ex` |
| &nbsp;&nbsp;&nbsp;&nbsp;• Compensation | Undo / cleanup on failure |  | `exec/compensation.ex` |
| &nbsp;&nbsp;&nbsp;&nbsp;• Telemetry | Emits `[:jido, :action, …]` events |  | `exec/telemetry.ex` |
| **Jido.Instruction** | Normalized "work order" struct wrapping an Action with params/context/runtime opts. Includes factory, normalization, validation helpers. | `new/1`, `normalize/2`, `validate_allowed_actions/2` | `lib/jido_instruction.ex` |
| **Jido.Plan** | Builder for DAGs of Instructions (step dependencies, parallel phases, etc.) | `new/1`, `add/4`, `build/2`, `execution_phases/1` | `lib/jido_plan.ex` |
| **Jido.Action.Tool** | Converts any Action into OpenAI-style tool/JSON schema. | `to_tool/1` | `lib/jido_action/tool.ex` |
| **Jido.Action.Error** | Typed error structs (`ValidationError`, `ExecutionFailureError`, …). | constructors & helpers | `lib/jido_action/error.ex` |

---

## 3. How the Pieces Fit  

```
Action            -> fundamental, validated unit of work
   ▲
Instruction       -> wraps Action + params/context for runtime
   ▲
Plan (DAG)        -> groups Instructions with dependencies
   │                   (build-time)
   ▼
Exec              -> executes Actions / Instructions /
                      Plans with retries, async, telemetry
   │
   └── Tool serializer -> exposes any Action to LLMs
```

---

## 4. Built-in Tools Catalogue  

### 4.1 Basic Utilities (`jido_tools/basic.ex`)
- Sleep            – pause `duration_ms`
- RandomSleep      – random delay `min_ms..max_ms`
- Log              – log `message` at `level`
- Todo             – placeholder reminder
- Increment / Decrement
- Noop             – pass-through
- Inspect          – `IO.inspect/2`
- Today            – formatted current date

### 4.2 Arithmetic (`jido_tools/arithmetic.ex`)
- Add, Subtract, Multiply, Divide, Square

### 4.3 File-system (`jido_tools/files.ex`)
- WriteFile        – create/append file
- ReadFile
- CopyFile
- MoveFile
- DeleteFile       – optional recursive / force
- MakeDirectory
- ListDirectory    – glob / recursive

### 4.4 Weather (NWS API)  
Top-level `Jido.Tools.Weather` unified entry plus lower-level helpers:
- ByLocation
- LocationToGrid
- Forecast
- HourlyForecast
- CurrentConditions

### 4.5 GitHub Issues (`jido_tools/github/issues.ex`)
- Create
- List
- Filter
- Find
- Update

### 4.6 Simple Robot Simulation (`jido_tools/simplebot.ex`)
- Move
- Idle
- DoWork
- Report
- Recharge

### 4.7 Workflow Helpers  
- `Jido.Tools.Workflow` – DSL-driven step/branch/parallel mini-workflow Action
- `Jido.Tools.ActionPlan` – Action that builds & executes a `Jido.Plan`
- `Jido.Tools.ReqTool` – Macro for quickly wrapping HTTP calls via `Req`

*(Total: 25+ concrete Actions, 5+ meta-tool helpers.)*

---

## 5. File Path Reference  

| Path | Module(s) | Category |
|------|-----------|----------|
| `lib/jido_action.ex` | Jido.Action | Core behaviour |
| `lib/jido_action/exec.ex` | Jido.Exec | Exec engine |
| `lib/jido_action/exec/retry.ex` | Jido.Exec.Retry | Exec helper |
| `lib/jido_action/tool.ex` | Jido.Action.Tool | AI integration |
| `lib/jido_instruction.ex` | Jido.Instruction | Instruction |
| `lib/jido_plan.ex` | Jido.Plan | Plan |
| `lib/jido_tools/basic.ex` | Sleep, Log, … | Utilities |
| `lib/jido_tools/arithmetic.ex` | Add, … | Math |
| `lib/jido_tools/files.ex` | WriteFile, … | FS |
| `lib/jido_tools/weather/*.ex` | Weather family | External API |
| `lib/jido_tools/github/issues.ex` | GitHub issue actions | External API |
| `lib/jido_tools/simplebot.ex` | Robot sim actions | Example |
| `lib/jido_tools/workflow.ex` | Workflow macro | Meta-tool |
| `lib/jido_tools/action_plan.ex` | ActionPlan macro | Meta-tool |
| `lib/jido_tools/req.ex` | ReqTool macro | HTTP meta-tool |

---

## 6. Navigation Tips  

1. Want to add a new Action? Start with `Jido.Action` in `lib/jido_action.ex` for macro options and examples.  
2. Need to execute one or many Actions? Look at `Jido.Exec` (sync/async) or build a DAG with `Jido.Plan`.  
3. Writing custom workflows quickly? Use `Jido.Tools.Workflow` (AST DSL) or `Jido.Tools.ActionPlan` (Plan builder).  
4. Integrate with an LLM? Call `YourAction.to_tool/0` – implementation lives in `tool.ex`.  
5. Searching for ready-made functionality? Browse `lib/jido_tools/` – each file groups a family of Actions.  

---

### Contributing  

Add new tools under `lib/jido_tools/<your_category>.ex`; follow patterns from existing modules. Unit tests belong in `test/jido_tools/`.  

Happy hacking!
