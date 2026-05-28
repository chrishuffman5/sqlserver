-- =====================================================================
-- a09-query-hotspots.sql  —  dimension: Query hotspots
-- PREREQUISITE: run analysis/00-load.sql first.
-- FINDS: (1) top queries by total CPU (total_worker_time_ms);
--        (2) top queries by total logical reads;
--        (3) expensive-per-call queries (high avg_* AND high execution_count).
-- NOTE: query_stats comes from the volatile plan cache (cleared on restart /
--   memory pressure / recompile) — it is a snapshot, not full history; use
--   Query Store for "what changed". Cross-reference a06 missing_indexes for
--   the same database. Depth: sqlserver-monitoring (live waits/Query Store),
--   sqlserver-engineering (the actual rewrite/index).
-- =====================================================================

-- (1) Top CPU consumers — capped to top 15 by total worker time.
WITH by_cpu AS (
    SELECT *, ROW_NUMBER() OVER (ORDER BY total_worker_time_ms DESC) AS rn
    FROM query_stats
)
SELECT
    'Query hotspots'                                        AS dimension,
    COALESCE(q.database_name, '(unknown)')                  AS database_name,
    'query_hash ' || q.query_hash                           AS object_name,
    CASE WHEN q.rn <= 3 THEN 'High' WHEN q.rn <= 8 THEN 'Medium' ELSE 'Low' END  AS severity,
    'total_cpu=' || fmt_n(q.total_worker_time_ms) || ' ms'
        || '; execs=' || fmt_n(q.execution_count)
        || '; avg_cpu=' || fmt_d(q.avg_worker_time_ms, 1) || ' ms'
        || '; text=' || left(COALESCE(q.sample_query_text, ''), 120)  AS metric,
    'Top CPU-consuming query in the plan cache.'            AS finding,
    'Capture the actual plan; check SARGability, cardinality estimates, and missing-index hints (see a06) before tuning. [INVESTIGATE]' AS recommendation,
    'High aggregate CPU is where tuning effort pays back most; total worker time ranks the biggest CPU burners across the workload.' AS why,
    'sqlserver-engineering'                                 AS consult_skill
FROM by_cpu q
WHERE q.rn <= 15

UNION ALL

-- (2) Top logical-read consumers — capped to top 15. Heavy reads usually
--     point at a missing/covering index or a scan that should be a seek.
SELECT
    'Query hotspots'                                        AS dimension,
    COALESCE(q.database_name, '(unknown)')                  AS database_name,
    'query_hash ' || q.query_hash                           AS object_name,
    CASE WHEN q.rn <= 3 THEN 'High' WHEN q.rn <= 8 THEN 'Medium' ELSE 'Low' END  AS severity,
    'total_reads=' || fmt_n(q.total_logical_reads)
        || '; execs=' || fmt_n(q.execution_count)
        || '; avg_reads=' || fmt_n(q.avg_logical_reads)
        || '; text=' || left(COALESCE(q.sample_query_text, ''), 120)  AS metric,
    'Top logical-read (I/O) query in the plan cache.'       AS finding,
    'Look for scans that should be seeks and missing covering indexes (cross-reference a06 for this database). [INVESTIGATE]' AS recommendation,
    'High logical reads drive buffer-pool churn and I/O waits; an index or rewrite often collapses the read count dramatically.' AS why,
    'sqlserver-engineering'                                 AS consult_skill
FROM (
    SELECT *, ROW_NUMBER() OVER (ORDER BY total_logical_reads DESC) AS rn
    FROM query_stats
) q
WHERE q.rn <= 15

UNION ALL

-- (3) Expensive AND frequent — high average elapsed time combined with a
--     high execution count: individually slow and run a lot (compounding).
SELECT
    'Query hotspots'                                        AS dimension,
    COALESCE(q.database_name, '(unknown)')                  AS database_name,
    'query_hash ' || q.query_hash                           AS object_name,
    'High'                                                  AS severity,
    'avg_elapsed=' || fmt_d(q.avg_elapsed_time_ms, 1) || ' ms'
        || '; execs=' || fmt_n(q.execution_count)
        || '; avg_reads=' || fmt_n(q.avg_logical_reads)
        || '; grant_kb=' || fmt_n(q.total_grant_kb)
        || '; text=' || left(COALESCE(q.sample_query_text, ''), 120)  AS metric,
    'Query is both expensive per call and executed frequently.' AS finding,
    'Prioritise this for tuning — per-call cost multiplies by frequency; verify it is not row-by-row (RBAR) from the app. [INVESTIGATE]' AS recommendation,
    'Cost x frequency is the true workload burden; a query that is slow AND hot dominates total resource use even if neither metric is extreme alone.' AS why,
    'sqlserver-engineering'                                 AS consult_skill
FROM query_stats q
WHERE q.avg_elapsed_time_ms >= 100
  AND q.execution_count    >= 1000
;
