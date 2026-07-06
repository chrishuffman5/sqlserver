-- =====================================================================
-- a16-identity-exhaustion.sql  —  dimension: Table design (identity runway)
-- PREREQUISITE: run analysis/00-load.sql first.
-- FINDS IDENTITY columns and SEQUENCEs consuming their data type's range from
-- the identity_columns capture. An int IDENTITY hitting 2,147,483,647 is a
-- full outage — every INSERT fails with arithmetic overflow (error 8115) —
-- and it is one of the most predictable failures in all of SQL Server.
--   Severity: >= 90% consumed High; >= 70% Medium; >= 50% Low.
-- Depth: sqlserver-engineering (type widening / reseed strategy).
-- NOTE: pct_used is NULL for descending increments, never-used objects, and
--   the collector marks cycling sequences (excluded — CYCLE cannot exhaust).
--   A negative reseed (e.g. DBCC CHECKIDENT to -2,147,483,648) doubles the
--   runway but breaks apps that assume positive IDs — a stopgap, not a fix.
-- =====================================================================

SELECT
    'Table design'                                          AS dimension,
    i.database_name                                         AS database_name,
    i.schema_name || '.' || i.table_name
        || COALESCE('.' || i.column_name, '')               AS object_name,
    CASE WHEN i.pct_used >= 90 THEN 'High'
         WHEN i.pct_used >= 70 THEN 'Medium' ELSE 'Low' END AS severity,
    i.object_type || ' ' || i.data_type
        || '; last_value=' || fmt_n(i.last_value)
        || ' of max=' || fmt_n(i.max_value)
        || ' (' || fmt_d(i.pct_used, 1) || '% used)'
        || '; increment=' || i.increment_value              AS metric,
    CASE WHEN i.pct_used >= 90
         THEN i.object_type || ' is nearly exhausted — INSERTs will start failing at the type maximum.'
         ELSE i.object_type || ' has consumed a significant share of its range.' END  AS finding,
    'Plan the fix before it is an outage: widen the type (int -> bigint is a size-of-data rebuild — schedule it), or reseed into the unused negative range as a stopgap if the app tolerates negative IDs. [SCHEMA CHANGE]' AS recommendation,
    'When an identity/sequence passes its type maximum every INSERT fails with error 8115 — a total write outage with zero prior symptoms, on a date you can compute today.' AS why,
    'sqlserver-engineering'                                 AS consult_skill
FROM identity_columns i
WHERE i.pct_used IS NOT NULL
  AND i.is_cycling = FALSE
  AND i.pct_used >= 50
ORDER BY i.pct_used DESC;
