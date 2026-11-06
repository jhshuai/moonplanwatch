# Changelog

## 0.2.0 — 2026-11-06

- `inspect` reports node identities, declared capture context, limitations and exact root buffer counters.
- `extract` recovers original UTF-8 plans from captures and protects existing files.
- `max_shared_writes` adds an inclusive root buffer budget.
- `compare --require-same-structure` enables a structural CI gate. Reports identify the first difference and name mismatched context fields.
- File errors and policy errors identify the affected path.
- Schema 1 stays in use. CI reads and extracts a capture produced by the original 0.1.0 executable.

## 0.1.0 — 2026-11-05

- Offline PostgreSQL 18 nonparallel SELECT profile with explicit unknown-data handling.
- Exact relation access rules, root UInt64 buffer budgets and disk-sort policy.
- Context-checked structural comparison and JSON/Markdown reports.
- Versioned capture envelope preserving original raw JSON and rejecting future schemas.
- CLI capture/check/compare with distinct pass, violation, invalid and incomplete exits.
- Public Chinook producer fixtures, isolated consumer and multi-backend verification.

This is a source release. Registry publication and prebuilt binaries are not included.
