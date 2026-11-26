\set ON_ERROR_STOP on
BEGIN;
CREATE TEMP TABLE diagnostic_events (a int, b int, lookup_id int);
CREATE TEMP TABLE diagnostic_lookup (id int PRIMARY KEY, payload text);
INSERT INTO diagnostic_lookup SELECT i, 'item-' || i FROM generate_series(1, 10000) AS i;
INSERT INTO diagnostic_events SELECT i % 100, i % 100, i FROM generate_series(1, 10000) AS i;
ANALYZE diagnostic_events;
ANALYZE diagnostic_lookup;
SET LOCAL max_parallel_workers_per_gather = 0;
SET LOCAL jit = off;
SET LOCAL enable_hashjoin = off;
SET LOCAL enable_mergejoin = off;
SET LOCAL enable_memoize = off;
\o :before_file
EXPLAIN (ANALYZE, VERBOSE, TIMING OFF, FORMAT JSON)
SELECT l.payload FROM diagnostic_events e
JOIN diagnostic_lookup l ON e.lookup_id = l.id WHERE e.a = 42 AND e.b = 42;
\o
CREATE STATISTICS diagnostic_dependencies (dependencies) ON a, b FROM diagnostic_events;
ANALYZE diagnostic_events;
\o :after_file
EXPLAIN (ANALYZE, VERBOSE, TIMING OFF, FORMAT JSON)
SELECT l.payload FROM diagnostic_events e
JOIN diagnostic_lookup l ON e.lookup_id = l.id WHERE e.a = 42 AND e.b = 42;
\o
ROLLBACK;
