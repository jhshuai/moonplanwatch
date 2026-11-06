# MoonPlanWatch

An offline PostgreSQL 18 query-plan policy library and CLI, written in MoonBit.

Database application developers repeatedly review `EXPLAIN` output after index,
ORM and deployment changes. MoonPlanWatch turns captured plans into explicit,
repeatable checks: forbid a sequential scan for an exact relation identity,
limit root buffer counters, or forbid disk-backed sorting. A comparison records
structural changes while requiring matching caller-declared capture contexts.

**Implemented:** bounded plan reading, lossless raw evidence envelopes,
conservative comparison, JSON/Markdown reports, and an executable offline workflow.
Unknown semantics or missing required metrics produce an incomplete result.
Costs, timing differences and structural changes are not treated as proof of a
performance regression. This program does not connect to a database or run SQL.

## Try it without PostgreSQL

Use MoonBit **0.10.19+bee578715** (toolchain and core). The committed fixtures were
captured from PostgreSQL **18.6** using the public Chinook 1.4.5 sample database.
Create a new `output` directory before these commands:

```text
moon run cmd/moonplanwatch -- --version
moon run cmd/moonplanwatch -- capture examples/chinook/indexed.json examples/chinook/context.json --output output/base.json
moon run cmd/moonplanwatch -- capture examples/chinook/sequential.json examples/chinook/context.json --output output/current.json
moon run cmd/moonplanwatch -- inspect output/base.json
moon run cmd/moonplanwatch -- extract output/base.json --output output/restored-plan.json
moon run cmd/moonplanwatch -- check output/base.json examples/policy-index.json
moon run cmd/moonplanwatch -- compare output/base.json output/current.json examples/policy-index.json --markdown
```

`check` passes with exit **0**. `compare` exits **1** and reports `SequentialScan`
and `StructureChanged`: only the first is a policy violation. Output creation
is exclusive; choose new filenames when repeating this example.

For an automatically isolated workflow, including all four exit statuses:

```text
moon run scripts/e2e.mbtx wasm
```

| Exit | Meaning |
|---|---|
| 0 | All requested checks pass within the supported profile |
| 1 | Explicit policy violation |
| 2 | Invalid input, unsupported envelope version, usage or I/O error |
| 3 | Incomplete evidence; takes precedence over violations |

`extract` restores the original UTF-8 plan, including unsupported fields and
original whitespace, to a new file for use in other PostgreSQL tools.

`inspect` lists node paths, relation selectors, index names and capture limitations
in JSON. It exits 0 for supported evidence, 3 for incomplete evidence, or 2 for
invalid input.

The `context` object in `inspect` shows the five declarations used for
compatibility checks. Save that object as JSON to reuse it with `capture`
after confirming the declarations still apply. Library callers can use
`Context::to_json()` to obtain the same object.

`inspect` also reports the inclusive root buffer counts used by the budget
checks. `root_buffers` uses decimal strings to preserve UInt64 precision and
`null` for a counter absent from the capture. Library callers can read the
same counters with `Capture::root_buffers()`.

Use `compare --require-same-structure` when CI must enforce the same node paths,
types, relations and index names as the baseline. A structural change then
produces exit 1. Incompatible or incomplete evidence still produces exit 3.

`capture` archives valid input even if its profile is incomplete; it does not run
the policy gate. Gate commands emit reports on stdout for exits 0, 1 and 3;
diagnostics for exit 2 go to stderr. File read, creation and write diagnostics
identify the affected path. Never convert a nonzero gate to success in CI.

## Three workflows

1. **Index migration review:** capture the same selective track lookup before and
   after dropping the demo index. Declare the same query/parameters/data/settings
   context, select `moonplanwatch_demo.track` with alias `track`, and forbid its
   sequential scan. Review the structured diagnostic before approving the migration.
2. **Resource budget in CI:** capture a safe SELECT with `ANALYZE, BUFFERS,
   VERBOSE, FORMAT JSON`; apply `examples/policy-resources.json`. The real sort
   fixture used disk and wrote 79 temporary blocks on the recorded Windows run.
   Missing metrics fail as incomplete; root counters are never summed with children.
3. **Deployment investigation:** preserve raw plans in versioned captures, share
   them without database credentials, and compare equivalent environments offline.
   For a server upgrade or changed dataset/settings, the initial profile returns
   `ContextMismatch` until separately reviewed; it does not manufacture equivalence.

See [the complete walkthrough](docs/workflow.md), [format and correctness contract](docs/contract.md),
[ecosystem boundaries](docs/ecosystem.md) and [verification record](docs/validation.md).

## Use the library

The root package has no third-party dependencies, I/O, clock or mutable global
state. Its public interface is checked in as [pkg.generated.mbti](pkg.generated.mbti).

```moonbit nocheck
let capture = @watch.read_plan(raw_json, @watch.decode_context(context_json))
let restored = @watch.decode_capture(capture.encode())
let policy = @watch.decode_policy(policy_json)
let report = @watch.evaluate(restored, policy)
println(report.to_json())
// Or: @watch.compare(baseline, restored, policy)
```

Import `jhshuai/moonplanwatch` as `@watch` in `moon.pkg`. The independent
[consumer](examples/consumer) shows the full configuration; validate it from
source with `moon run scripts/consumer.mbtx wasm`. No registry publication is
required: the script builds an isolated two-module `moon.work` workspace.

## Scope and development

The library targets Wasm, Wasm-GC, JavaScript and native. The filesystem CLI
targets Wasm (`moonrun`) and native. CLI and automation use the toolchain's
experimental `core/async` APIs, so the toolchain is pinned. Browser filesystem
support and native binaries are not distributed in this initial source release.

```text
moon fmt --check
moon info
moon check --deny-warn
moon test --deny-warn
moon run scripts/verify.mbtx wasm
```

CI runs the library and independent consumer across four backends on Windows,
Linux and macOS; Wasm/native also execute the real CLI workflow. A PostgreSQL
service job regenerates plans and checks them through the same offline workflow.

**Planned, not implemented:** additional PostgreSQL node profiles backed by real
fixtures, explicitly defined upgrade comparison modes, then batch manifests for
multiple named queries. New profiles must preserve incomplete outcomes and old
evidence; no automatic baseline replacement or SQL execution is planned in the core.

Apache-2.0. See [THIRD_PARTY.md](THIRD_PARTY.md) for sample data, reused code and references.
