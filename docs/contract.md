# Input and policy contract — 0.2.0

## Evidence

`read_plan(raw, context)` requires one JSON array containing exactly one object
with a `Plan`. Context requires five nonblank identifiers of at most 256 UTF-16
units: `query_id`, `parameters_id`, `dataset_id`, `settings_id`, `server_version`.
The version must be numeric PostgreSQL `18.x`. Context is supplied by the caller;
it is not verified against a database and is not a signed provenance record.
Comparison requires equality of all five declarations, including the server patch
version. A changed index is the subject of review, so index identity is in the
plan rather than the context. Dataset identity describes rows/statistics, not DDL.

Supported node kinds: Seq Scan, Index Scan, Index Only Scan, Bitmap Heap Scan,
Bitmap Index Scan, Nested Loop, Hash Join, Merge Join, Hash, Sort, Aggregate, Limit,
Result, Materialize, Unique, Subquery Scan and Append. `Plans` children are visited
in source order, with JSON Pointer paths. Relation scans require VERBOSE identity:
Schema, Relation Name and Alias. Index scans also require Index Name.

Parallel/async/disabled plans, unknown node kinds, unknown top-level or node
fields, and nonempty trigger evidence make the profile incomplete. Original
source is always retained; no transformation discards unknown values.
Decision fields are type-checked. Recognized nondecision metadata, such as Output,
Filter, estimated costs and timing, is retained without semantic interpretation;
this is not a complete validator for every PostgreSQL EXPLAIN property. Unknown
extensions must gain explicit profile support before they can pass.

Input limits: raw plan 524,288 UTF-16 units; configuration/evidence envelope
4,194,304 units; JSON nesting depth 64; 10,000 nodes; 256 access rules. Node and
raw size limits are independent. CLI reads only regular UTF-8 files with a 16 MiB
byte limit checked during reading. Invalid UTF-8, duplicate decoded object keys,
invalid JSON and excess limits are rejected. These bounds are input guards, not
a guarantee of a fixed memory footprint.

`Capture.encode()` writes `{schema:1,kind:"moonplanwatch/capture",context:...,
plan_source:...}` as JSON. `plan_source` is the original text, including whitespace,
numeric spelling and unknown data. Reading an envelope revalidates both layers.
The raw size bound ensures even maximally escaped source fits the envelope limit.
Capture arrays and policy rule arrays are copied at the API boundary.

## Policies

```json
{"schema":1,"access":[{"schema":"public","relation":"orders","alias":"o","allow_sequential":false}],"max_shared_reads":128,"max_temp_writes":0,"forbid_disk_sort":true}
```

Only `schema` is required. Absent budget means no check; explicit zero is a real
budget. An empty policy checks supported-profile completeness, not performance.
Unknown configuration keys and future schema versions are errors. Access rules
default `allow_sequential` to false; other booleans default false. Duplicate
relation selectors are rejected. Optional fields must be omitted, never null.

Each selector must match exactly one schema/relation/alias scan. Zero or multiple
matches produce `AmbiguousRelation` and exit 3. No fuzzy matching or automatic
alias matching is attempted. A selected Seq Scan violates a forbidding rule even
if runtime loops were zero: this is a structural access policy.

Shared Read Blocks, Shared Written Blocks and Temp Written Blocks are exact UInt64 decimal integer
literals. Signs, fractions, exponent notation, overflow and nonnumeric values
are errors. No conversion through Double determines a budget. Only the root's
inclusive counters are checked: parent/child values are not added. These are
PostgreSQL blocks, not bytes, per-loop averages or elapsed time. A required but
absent counter produces exit 3, not zero usage. Disk-sort checks require each
Sort node's Sort Space Type; Memory passes, Disk violates, absence is incomplete.

Set `max_shared_writes` to cap the root's Shared Written Blocks counter. For
example, `{"schema":1,"max_shared_writes":0}` requires a recorded zero. This
counter measures shared buffers written during execution. It differs from the
number of buffers dirtied and can vary with cache state.

## Comparison and reports

Policy diagnostics use JSON Pointer paths such as
`/access/1/allow_sequential` to identify the exact rule and field to edit.

Current policy findings are preserved. Context mismatch diagnostics name the
fields that differ. Baseline limitations and context mismatch
also cause exit 3. Equivalent contexts allow a `StructureChanged` observation
when preorder node kind/path/relation/index identity differs. The report shows
the first differing slot and its before/after node descriptions. Filter expressions,
join conditions, cost, timing and index definitions are outside the comparison.
With `require_same_structure=true` or `--require-same-structure`, the same
finding becomes a violation. Resource budgets still apply to the current
capture's counters. Incomplete evidence takes precedence in both modes.

Exit precedence is incomplete (3), violation (1), pass (0); parsing/I/O errors
are separate (2 in CLI). Reports retain violations even when incomplete. Finding
order is stable: limitations (unknown field names sorted per object), access
rules in policy order, budgets, sorts, then baseline/context/structure findings.
Repeated runs have identical output; no timestamp is inserted. Markdown escapes
caller-controlled markup and line breaks. JSON is the machine interface.

## Versioning and unsupported inputs

Capture, policy and report schema numbers are independent of package SemVer.
Schema 1 is the only supported input version. Unknown envelope fields are errors,
never silently removed. Committed raw fixtures and the end-to-end roundtrip are
the initial compatibility baseline; future readers must retain these tests.
A future incompatible reader/writer will require a new schema plus documented
migration, and must not overwrite the original evidence in place.

Not supported: other PostgreSQL majors, text/XML/YAML plans, SQL parsing, DML,
parallel worker aggregation, automatic tuning, query execution, live monitoring,
schema/index-definition comparison, timing regression claims, and cryptographic
authenticity. Extensions such as custom scans/JIT and unknown fields return
incomplete or clear parse diagnostics rather than optimistic success.
