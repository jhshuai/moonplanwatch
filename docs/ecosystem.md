# Scope and ecosystem review

Reviewed 2026-11-05 before implementation. The recurring task is reviewing
PostgreSQL plans after application/index changes and carrying explicit checks
into CI/offline debugging. This spans ordinary database application teams rather
than a specialized file format audience. Established tools such as
[PEV2](https://github.com/dalibo/pev2) and [PgHero](https://github.com/ankane/pghero)
provide independent demand evidence for plan inspection/query troubleshooting;
their popularity is not evidence that teams already adopt this particular API.

MoonPlanWatch's public boundary is captured PostgreSQL plan + caller context +
explicit policy → conservative offline gate, with original evidence retained.
MoonBit is suitable because the decision logic can be pure typed code on four
backends, while the filesystem/process boundary stays in a separate CLI package.
Core JSON/UTF-8 avoid introducing a second generic parsing framework.

| Existing MoonBit work | Public boundary / scope reviewed | License; observed activity | Relationship |
|---|---|---|---|
| [jaredzhou/moonpg](https://github.com/jaredzhou/moonpg), [Mooncakes](https://mooncakes.io/docs/jaredzhou/moonpg) | Connection/query/execute/fetch PostgreSQL driver APIs | Apache-2.0; v0.14.0, repository pushed 2026-10-16 | Can collect a plan upstream; does not supply this offline evidence/policy contract |
| [cn-xjr/MigrationLens](https://github.com/cn-xjr/MigrationLens) | review_sql, review_migrations, compare_reports: static migration analysis | Apache-2.0; pushed 2026-10-27 | Reviews migration statements; MoonPlanWatch reviews a captured planner decision for a query |
| [Ljh684/sqlsentinel](https://github.com/Ljh684/sqlsentinel) | scan_sql, scan_sql_with: SQL/schema risk checks | Apache-2.0; pushed 2026-11-04 | Static SQL analysis; no replacement for captured plan evidence |
| [mizchi/sqlc_gen_moonbit](https://github.com/mizchi/sqlc_gen_moonbit) | sqlc code generation/protobuf models, including PostgreSQLExplain_Plan | Apache-2.0; v0.4.0, pushed 2026-08-23 | Sharing a model name does not provide conservative gates or a preservation workflow |
| [JQ-ai-nb/relcore](https://github.com/JQ-ai-nb/relcore) | Own relational plan/table execution, execute/check_contracts, exact row cardinality | MIT; v0.2.6, pushed 2026-10-25 | Executes its own IR; MoonPlanWatch neither executes queries nor defines a relational engine |
| [mizchi/skills sql-plan-audit](https://github.com/mizchi/skills/tree/main/skills/sql-plan-audit) | Agent workflow around SQLite/D1 plan capture and baseline review | License not established in the inspected resource; not reused | Closest workflow reference; a separate backend/skill interface, not a MoonBit PostgreSQL library |

Activity is the repository's observed push date, not a claim of continuing
maintainer support. These projects are complementary at the reviewed API boundary;
none of the reviewed APIs was replaced or wrapped as this project's core logic.

Searches covered Mooncakes names/descriptions/docs, GitHub and community sources
with combinations of `MoonBit`, `EXPLAIN`, `PostgreSQL`, `query plan`, `plan diff`,
`regression`, `SQL audit`, `baseline`, `policy`, `SQLite`, `D1`, `query optimizer`,
and Chinese `执行计划` / `回归`. SQL parsers, database drivers, migration checkers
and relational engines were inspected as adjacent categories, not dismissed by
their names. [Official EXPLAIN semantics](https://www.postgresql.org/docs/18/using-explain.html)
guided the conservative scope, especially cost units and inclusive counters.

This review cannot exhaust private, unpublished, poorly indexed or newly created
packages, nor guarantee no undocumented API overlaps. It establishes a bounded
differentiation argument, not originality/uniqueness proof. If an existing package
adds this whole evidence/gate boundary, reassess integration and reduce scope
instead of continuing a duplicate implementation. No competitor source or tests
were copied; acknowledged reused I/O code and producer data are in THIRD_PARTY.md.
