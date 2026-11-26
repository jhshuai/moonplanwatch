# Diagnose a cardinality discrepancy

The included PostgreSQL 18.6 plans use generated tables with a = b in every
row. Two equality predicates select 100 rows. The first plan estimates one
row for the scan and join. The second plan estimates 100 after adding dependency
statistics. Both runs use the same query and generated rows. Session settings
keep a Nested Loop visible in both plans.

Run from the repository root with a fresh output filename.

```text
moon run cmd/moonplanwatch -- capture examples/cardinality/before.json examples/cardinality/context.json --output before.capture.json
moon run cmd/moonplanwatch -- analyze before.capture.json
```

The outer scan reports an underestimate of 100× and is marked as the deepest
confirmed discrepancy. The join reports the gap at its own output. The marker
identifies where to investigate. The controlled statistics change provides
additional evidence about the cause in this example.

The Nested Loop evidence pairs the immediate Outer and Inner children by their
PostgreSQL role. Both captures record 100 inner invocations and 100 index
searches. Dividing observed inner invocations per join execution by the outer
row estimate gives 100 before the statistics change and 1 after it. The
denominator is an outer-row reference, and the ratio describes a difference in
estimated versus observed scale. The output separately reports approximate
inner rows from the displayed average multiplied by inner loops. Repeated
invocations, index searches and output rows measure different quantities.

Analysis compares the observed rows per execution with the planner estimate.
Repeated executions use an allowance for the printed two-decimal average.
Unexecuted nodes, bitmap index counters and descendants of known early-stop
operators have distinct statuses. Missing or invalid metrics return exit 3.
An exit of 0 indicates that the analysis ran successfully.

To reproduce, use a disposable PostgreSQL 18 session. The SQL creates temporary
tables inside a transaction and rolls it back. Supply fresh output paths because
psql replaces files named by its output command.

```text
psql -X -qAt -v before_file=fresh-before.json -v after_file=fresh-after.json -f examples/cardinality/reproduce.sql
```

For automatic verification, set the standard PostgreSQL connection environment
variables for the disposable server and run the same command used in CI. Create
the parent of the destination first.

```text
moon run scripts/cardinality-e2e.mbtx psql output/cardinality-live
```

CI retains both generated plans and the context as the
`postgres-cardinality-evidence` artifact.
