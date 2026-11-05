# Capture → archive → review

## Offline, public-data example

Run `moon run scripts/e2e.mbtx wasm` from the repository root. It creates a unique
temporary directory and removes only that directory. It executes the real CLI
as child processes and checks their exit statuses and report bodies:

| Captured input | Policy/workflow | Expected |
|---|---|---|
| indexed.json | Exact track selector forbids Seq Scan | 0 |
| indexed → sequential | Same declarations, same selector | 1 + structural observation |
| analyzed-sort.json | No disk sort / zero temp writes | 1 |
| indexed.json | Runtime buffer budgets without ANALYZE | 3 |
| lookup → sort | Different declared query/parameters | 3 |
| Existing output, malformed JSON/UTF-8, missing file | Input/output validation | 2 |
| Valid indexed input after errors | Recovery and unchanged source | 0 |

For the sort manually, use new output paths:

```text
moon run cmd/moonplanwatch -- capture examples/chinook/analyzed-sort.json examples/chinook/sort-context.json --output output/sort.json
moon run cmd/moonplanwatch -- check output/sort.json examples/policy-resources.json --markdown
```

The committed fixture reports an actual external merge sort: 296 KiB sort space
and 79 root temporary blocks written. These are one recorded run, not a speed
benchmark or a threshold every machine must reproduce. The fixture dataset has
3,503 tracks; names come from the public Chinook sample, not a production capture.

## Reproduce with PostgreSQL

Use a disposable PostgreSQL 18 database, a `psql` executable and `curl`. Configure
the usual `PGHOST`, `PGPORT`, `PGUSER`, `PGDATABASE` and (if needed) `PGPASSWORD`
environment variables. Do not put credentials in source or capture contexts.

```text
moon run scripts/capture-chinook.mbtx psql output/fresh-chinook
moon run scripts/e2e.mbtx wasm output/fresh-chinook
```

The producer downloads the pinned SQL listed in THIRD_PARTY.md. It validates and
removes the upstream database-creation preamble, creates a new dedicated
`moonplanwatch_demo` schema in a transaction, and loads the remaining data there.
It refuses an existing destination or existing schema. After successful setup it
removes only its own schema on both normal completion and handled errors.
An interrupted process may leave that schema for manual inspection/removal.

It adds its own track-name index, runs ANALYZE, captures the lookup, removes only
that demo index, and captures the same lookup again. Then it captures a sorted
SELECT with ANALYZE/BUFFERS. Both lookup captures use identical rows, SQL and
session settings; the demo index is the intentional change. It sets parallel
workers to zero, JIT off and work_mem to 64kB; other settings remain database
defaults. Context identifiers are declarations, not exhaustive configuration
fingerprints. For a real service, assign identities after reviewing all relevant
settings, extensions, statistics and data. Planner choices and buffer counts can
vary: the E2E assertions deliberately fail if the expected plans are not produced.

The fixture header SQL itself can drop/create a database, but that preamble is
never sent to the database by this producer. The offline core and CLI have no
database connection capability. EXPLAIN ANALYZE really executes a statement;
the producer's only analyzed statement is the committed safe sample SELECT.

## Development checks

`moon run scripts/verify.mbtx TARGET` checks formatting, interface drift, strict
check/build, unit tests and an isolated consumer. Wasm/native additionally execute
the CLI E2E. Use one of wasm, wasm-gc, js or native. Native on Windows requires
MSVC C++ tools and a Windows SDK; configure the developer environment before
running it. On Linux/macOS use a supported system C compiler.

The producer integration job also tests existing-directory/schema refusal, cleanup after
a handled output collision, and a successful run after that failure. Run it with
`moon run scripts/producer-e2e.mbtx psql NEW_DIRECTORY` on a disposable database.
CI logs and
fixture artifacts are the evidence of each run; a workflow definition alone is
not proof of an executed platform.
