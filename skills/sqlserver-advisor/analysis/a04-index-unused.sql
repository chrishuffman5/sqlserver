-- =====================================================================
-- a04-index-unused.sql  —  dimension: Indexing
-- PREREQUISITE: run analysis/00-load.sql first.
-- FINDS: (1) nonclustered, non-PK, non-unique-constraint indexes that are
--            WRITTEN to but never READ (drop candidates), with a read:write
--            ratio fallback; (2) DISABLED indexes (dead weight on disk).
-- CONFIDENCE NOTE: index_usage counters reset on instance restart. When the
--   server has been up only briefly, "0 reads" may just mean "no reads YET",
--   so severity is lowered and the 'why' says so. Depth: sqlserver-engineering.
-- =====================================================================

-- Server uptime (days) drives a confidence damper. dm_db_index_usage_stats
-- accumulates only since the last restart, so short uptime => weak evidence.
WITH uptime AS (
    SELECT
        server_name,
        date_diff('day', sqlserver_start_time, captured_at) AS uptime_days
    FROM server_info
)

-- (1) Unused / write-only nonclustered indexes — every index is maintained
--     on every INSERT/UPDATE/DELETE, so a write-heavy, never-read index is
--     pure overhead. Exclude PKs and unique constraints (they enforce
--     integrity even with zero reads).
SELECT
    'Indexing'                                              AS dimension,
    iu.database_name,
    iu.schema_name || '.' || iu.table_name || '.' || iu.index_name  AS object_name,
    CASE
        WHEN COALESCE(u.uptime_days, 0) < 7 THEN 'Low'      -- weak evidence yet
        WHEN iu.user_updates >= 100000 THEN 'High'
        WHEN iu.user_updates >= 1000   THEN 'Medium'
        ELSE 'Low'
    END                                                     AS severity,
    'reads=' || (iu.user_seeks + iu.user_scans + iu.user_lookups)
        || ' (seeks=' || iu.user_seeks || ', scans=' || iu.user_scans || ', lookups=' || iu.user_lookups || ')'
        || '; writes=' || fmt_n(iu.user_updates)
        || '; uptime=' || COALESCE(u.uptime_days, 0) || 'd' AS metric,
    CASE WHEN (iu.user_seeks + iu.user_scans + iu.user_lookups) = 0
         THEN 'Nonclustered index is written but never read.'
         ELSE 'Nonclustered index is read far less than it is written (low read:write ratio).'
    END                                                     AS finding,
    'Confirm across a representative workload window, then consider dropping (or disabling) this index. [SCHEMA CHANGE] validate in non-prod.' AS recommendation,
    CASE WHEN COALESCE(u.uptime_days, 0) < 7
         THEN 'Index maintenance cost is paid on every write with little/no read benefit — but usage counters reset at restart and uptime is only '
              || COALESCE(u.uptime_days, 0) || ' day(s), so treat this as low-confidence until a fuller window is observed.'
         ELSE 'Index maintenance cost is paid on every write with little/no read benefit; dropping it reduces write amplification and storage.'
    END                                                     AS why,
    'sqlserver-engineering'                                 AS consult_skill
FROM index_usage iu
JOIN indexes i
      ON  i.database_name = iu.database_name
      AND i.schema_name   = iu.schema_name
      AND i.table_name    = iu.table_name
      AND i.index_id      = iu.index_id
LEFT JOIN uptime u ON u.server_name = iu.server_name
WHERE i.index_type_desc = 'NONCLUSTERED'
  AND i.is_primary_key       = FALSE
  AND i.is_unique_constraint = FALSE
  AND i.is_disabled          = FALSE
  AND iu.user_updates > 0
  AND (
        (iu.user_seeks + iu.user_scans + iu.user_lookups) = 0           -- never read
        OR ( iu.user_updates >= 1000                                    -- or read:write <= ~1%
             AND (iu.user_seeks + iu.user_scans + iu.user_lookups)
                 < iu.user_updates * 0.01 )
      )

UNION ALL

-- (2) Disabled indexes — they consume catalog/metadata, are not maintained,
--     and silently stop helping queries. Either rebuild (re-enable) or drop.
SELECT
    'Indexing'                                              AS dimension,
    i.database_name,
    i.schema_name || '.' || i.table_name || '.' || i.index_name  AS object_name,
    'Medium'                                                AS severity,
    'index_type=' || i.index_type_desc || '; is_disabled=true'   AS metric,
    'Index is disabled.'                                    AS finding,
    'Decide deliberately: REBUILD to re-enable if it is needed, or DROP it if it is obsolete. [SCHEMA CHANGE]' AS recommendation,
    'A disabled index helps no query yet lingers in metadata; a disabled clustered index also makes the whole table inaccessible.' AS why,
    'sqlserver-engineering'                                 AS consult_skill
FROM indexes i
WHERE i.is_disabled = TRUE
;
