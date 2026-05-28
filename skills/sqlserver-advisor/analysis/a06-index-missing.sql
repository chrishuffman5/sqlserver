-- =====================================================================
-- a06-index-missing.sql  —  dimension: Indexing
-- PREREQUISITE: run analysis/00-load.sql first.
-- FINDS: the top missing-index suggestions by improvement_measure, capped
--        to the highest-value ones. Suggestions on WRITE-HEAVY tables (joined
--        to index_usage updates) are flagged "consolidate, do not just add".
-- CAVEAT: the missing-index DMVs ignore existing indexes and write cost and
--   never consolidate overlapping suggestions — they are HINTS, not orders.
-- Depth on consolidating/designing the real index: sqlserver-engineering.
-- =====================================================================

-- Cap: keep the top 25 suggestions instance-wide by improvement_measure
-- (= avg_total_user_cost * avg_user_impact/100 * (seeks+scans)). The list is
-- intentionally capped; lower-value suggestions are omitted as noise.
WITH writes_per_table AS (
    -- total write activity per table, summed across its existing indexes
    SELECT database_name, schema_name, table_name,
           SUM(user_updates) AS table_user_updates
    FROM index_usage
    GROUP BY database_name, schema_name, table_name
),
ranked AS (
    SELECT
        mi.*,
        ROW_NUMBER() OVER (ORDER BY mi.improvement_measure DESC) AS rn
    FROM missing_indexes mi
)
SELECT
    'Indexing'                                              AS dimension,
    r.database_name,
    r.schema_name || '.' || r.table_name                    AS object_name,
    CASE WHEN r.improvement_measure >= 100000 THEN 'High'
         WHEN r.improvement_measure >= 10000  THEN 'Medium'
         ELSE 'Low' END                                     AS severity,
    'improvement=' || fmt_n(r.improvement_measure)
        || '; seeks=' || r.user_seeks || '; scans=' || r.user_scans
        || '; avg_impact=' || fmt_n(r.avg_user_impact) || '%'
        || '; eq=(' || COALESCE(r.equality_columns, '') || ')'
        || '; ineq=(' || COALESCE(r.inequality_columns, '') || ')'
        || '; incl=(' || COALESCE(r.included_columns, '') || ')'
        || CASE WHEN COALESCE(w.table_user_updates, 0) >= 100000
                THEN '; table_writes=' || fmt_n(w.table_user_updates) || ' (write-heavy)'
                ELSE '' END                                 AS metric,
    CASE WHEN COALESCE(w.table_user_updates, 0) >= 100000
         THEN 'High-impact missing index on a WRITE-HEAVY table — consolidate, do not just add.'
         ELSE 'High-impact missing-index suggestion.'
    END                                                     AS finding,
    CASE WHEN COALESCE(w.table_user_updates, 0) >= 100000
         THEN 'Merge this suggestion with existing indexes (dedupe keys, fold payload into INCLUDE) and weigh the added write cost before creating. [SCHEMA CHANGE]'
         ELSE 'Design a real index from this hint: order keys equality-then-range, cover the SELECT with INCLUDE, and check for overlap with existing indexes first. [SCHEMA CHANGE]'
    END                                                     AS recommendation,
    'Missing-index DMV suggestions ignore existing indexes and write cost and are not consolidated; apply them only after design review.' AS why,
    'sqlserver-engineering'                                 AS consult_skill
FROM ranked r
LEFT JOIN writes_per_table w
       ON  w.database_name = r.database_name
       AND w.schema_name   = r.schema_name
       AND w.table_name    = r.table_name
WHERE r.rn <= 25                              -- CAP: top 25 by improvement_measure
;
