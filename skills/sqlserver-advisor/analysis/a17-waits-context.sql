-- =====================================================================
-- a17-waits-context.sql  —  dimension: Configuration (bottleneck context)
-- PREREQUISITE: run analysis/00-load.sql first.
-- FINDS the dominant bottleneck CLASS from the wait_stats capture (benign
-- waits already filtered by the collector) and routes it to the owning
-- subsystem:
--   (1) a dominant wait type (>= 25% of filtered wait time; High >= 50%) with
--       a per-class routed recommendation;
--   (2) high signal-wait ratio (>= 25%) — CPU/scheduler pressure.
-- Depth: routed per wait class; live drill-down always sqlserver-monitoring.
-- NOTE: wait counters are CUMULATIVE SINCE RESTART — this is a since-startup
--   average, not a live window. Short uptime (server_info.sqlserver_start_time)
--   makes these findings unreliable; the metric carries uptime for that reason.
--   CXPACKET is a symptom (usually low cost threshold), not a disease.
-- =====================================================================

-- (1) Dominant wait type, routed by class
SELECT
    'Configuration'                                         AS dimension,
    NULL                                                    AS database_name,
    '(instance) wait: ' || w.wait_type                      AS object_name,
    CASE WHEN w.pct_of_total >= 50 THEN 'High' ELSE 'Medium' END  AS severity,
    'pct_of_total=' || fmt_d(w.pct_of_total, 1) || '%; wait_time='
        || fmt_n(w.wait_time_ms) || ' ms; tasks=' || fmt_n(w.waiting_tasks_count)
        || '; uptime=' || COALESCE(u.uptime_days, 0) || 'd'  AS metric,
    'One wait type dominates the (benign-filtered) wait profile since restart.'  AS finding,
    CASE
        WHEN w.wait_type IN ('CXPACKET', 'CXCONSUMER')
            THEN 'Parallelism waits: raise cost threshold for parallelism and bound MAXDOP (see a10), then re-measure — do not chase CXPACKET itself. [INVESTIGATE]'
        WHEN starts_with(w.wait_type, 'PAGEIOLATCH_')
            THEN 'Buffer reads from disk: check memory pressure (page life), missing/covering indexes driving scans (a06/a09), and storage latency. [INVESTIGATE]'
        WHEN w.wait_type = 'WRITELOG'
            THEN 'Log-flush latency: check log-disk write latency, VLF health (a13), tiny commits/no batching, and synchronous AG/mirroring overhead. [INVESTIGATE]'
        WHEN starts_with(w.wait_type, 'LCK_')
            THEN 'Lock waits: find the blocking chains live (sqlserver-monitoring), then fix the holder — long transactions, missing indexes, or isolation choices (RCSI, a11). [INVESTIGATE]'
        WHEN w.wait_type = 'RESOURCE_SEMAPHORE'
            THEN 'Memory-grant queueing: hunt over-granting queries (a09 grants), fix cardinality misestimates, and review max server memory. [INVESTIGATE]'
        WHEN starts_with(w.wait_type, 'PAGELATCH_')
            THEN 'In-memory allocation contention (often tempdb PFS/GAM/SGAM): check tempdb data-file count (a13) and hot-page patterns (last-page insert). [INVESTIGATE]'
        WHEN w.wait_type = 'ASYNC_NETWORK_IO'
            THEN 'The CLIENT is consuming results slowly: look at app-side row-by-row processing and oversized result sets — this is rarely a server problem. [INVESTIGATE]'
        WHEN starts_with(w.wait_type, 'HADR_')
            THEN 'Availability-group synchronization: check replica health, network latency, and sync-commit cost (sqlserver-ha-clustering). [INVESTIGATE]'
        ELSE 'Identify the wait class in the wait-type reference (sqlserver-monitoring) and confirm live before acting — a snapshot ranks classes, it does not diagnose. [INVESTIGATE]'
    END                                                     AS recommendation,
    'The dominant wait names the bottleneck CLASS the instance spends its time on — it tells you which subsystem to investigate first, not which knob to turn.'  AS why,
    CASE
        WHEN w.wait_type IN ('CXPACKET', 'CXCONSUMER')      THEN 'sqlserver-infrastructure'
        WHEN w.wait_type = 'WRITELOG'                       THEN 'sqlserver-infrastructure'
        WHEN starts_with(w.wait_type, 'PAGELATCH_')               THEN 'sqlserver-infrastructure'
        WHEN w.wait_type = 'RESOURCE_SEMAPHORE'             THEN 'sqlserver-engineering'
        ELSE 'sqlserver-monitoring'
    END                                                     AS consult_skill
FROM wait_stats w
LEFT JOIN (
    SELECT server_name, date_diff('day', sqlserver_start_time, captured_at) AS uptime_days
    FROM server_info
) u ON u.server_name = w.server_name
WHERE w.pct_of_total >= 25

UNION ALL
-- (2) High signal-wait ratio — CPU/scheduler pressure
SELECT
    'Configuration', NULL, '(instance)',
    'Medium',
    'signal_wait_ratio=' || fmt_d(r.signal_ratio * 100, 1) || '% ('
        || fmt_n(r.signal_ms) || ' of ' || fmt_n(r.total_ms) || ' ms)'
        || '; uptime=' || COALESCE(r.uptime_days, 0) || 'd',
    'High signal-wait ratio: threads are runnable but queueing for a scheduler (CPU pressure).',
    'Reduce CPU demand before adding CPUs: tune the top CPU queries (a09), bound parallelism (a10), and confirm with live scheduler/runnable-task counts. [INVESTIGATE]',
    'Signal wait is time spent READY but not RUNNING — a high share means the CPUs cannot keep up with runnable work, independent of what the work waits on.',
    'sqlserver-infrastructure'
FROM (
    SELECT SUM(w.signal_wait_time_ms) AS signal_ms,
           SUM(w.wait_time_ms)        AS total_ms,
           SUM(w.signal_wait_time_ms) * 1.0 / NULLIF(SUM(w.wait_time_ms), 0) AS signal_ratio,
           MAX(u.uptime_days)         AS uptime_days
    FROM wait_stats w
    LEFT JOIN (
        SELECT server_name, date_diff('day', sqlserver_start_time, captured_at) AS uptime_days
        FROM server_info
    ) u ON u.server_name = w.server_name
) r
WHERE r.signal_ratio >= 0.25;
