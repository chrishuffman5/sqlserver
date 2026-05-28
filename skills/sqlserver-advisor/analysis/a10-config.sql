-- =====================================================================
-- a10-config.sql  —  dimension: Configuration
-- PREREQUISITE: run analysis/00-load.sql first.
-- FINDS instance-config smells from sp_configure values:
--   (1) 'cost threshold for parallelism' = 5 (default, too low);
--   (2) 'max degree of parallelism' = 0 on a multi-core host;
--   (3) 'optimize for ad hoc workloads' = 0 (plan-cache bloat risk);
--   (4) 'backup compression default' = 0 (larger/slower backups).
-- All object_name = '(instance)'. Depth: sqlserver-infrastructure.
-- NOTE: config defaults/best values are workload- and platform-dependent;
--   on Azure SQL DB many server-level settings are not user-configurable.
-- =====================================================================

-- (1) Cost threshold for parallelism still at the 1995-era default of 5.
SELECT
    'Configuration'                                         AS dimension,
    NULL                                                    AS database_name,
    '(instance)'                                            AS object_name,
    'Medium'                                                AS severity,
    'cost threshold for parallelism = ' || c.value_in_use   AS metric,
    'Cost threshold for parallelism is at the default of 5.' AS finding,
    'Raise it (commonly 25-50) so only genuinely expensive plans go parallel; tune with observed CXPACKET/CXCONSUMER. [CONFIG CHANGE]' AS recommendation,
    'A threshold of 5 sends trivial queries parallel, wasting workers and producing CXPACKET noise on OLTP workloads.' AS why,
    'sqlserver-infrastructure'                              AS consult_skill
FROM config c
WHERE c.config_name = 'cost threshold for parallelism'
  AND c.value_in_use = 5

UNION ALL

-- (2) MAXDOP = 0 (unlimited) on a multi-core host — every parallel query
--     can grab every scheduler. Join server_info for the core count.
SELECT
    'Configuration'                                         AS dimension,
    NULL                                                    AS database_name,
    '(instance)'                                            AS object_name,
    CASE WHEN s.host_cpu_count >= 16 THEN 'High' ELSE 'Medium' END  AS severity,
    'max degree of parallelism = 0; host_cpu_count = ' || s.host_cpu_count  AS metric,
    'MAXDOP is 0 (unlimited) on a multi-core host.'         AS finding,
    'Set MAXDOP to a bounded value (Microsoft guidance: typically up to 8, or the cores per NUMA node, whichever is lower). [CONFIG CHANGE]' AS recommendation,
    'MAXDOP 0 lets a single query consume every core, starving concurrent requests and amplifying parallelism waits.' AS why,
    'sqlserver-infrastructure'                              AS consult_skill
FROM config c
CROSS JOIN server_info s
WHERE c.config_name = 'max degree of parallelism'
  AND c.value_in_use = 0
  AND s.host_cpu_count > 1

UNION ALL

-- (3) Optimize for ad hoc workloads = 0 — single-use ad-hoc plans bloat cache.
SELECT
    'Configuration'                                         AS dimension,
    NULL                                                    AS database_name,
    '(instance)'                                            AS object_name,
    'Low'                                                   AS severity,
    'optimize for ad hoc workloads = ' || c.value_in_use    AS metric,
    'Optimize for ad hoc workloads is disabled.'            AS finding,
    'Enable it so first-time ad-hoc batches cache only a small plan stub, reducing plan-cache bloat from single-use queries. [CONFIG CHANGE]' AS recommendation,
    'Without it, every one-off ad-hoc query caches a full plan, wasting plan-cache memory on plans reused exactly once.' AS why,
    'sqlserver-infrastructure'                              AS consult_skill
FROM config c
WHERE c.config_name = 'optimize for ad hoc workloads'
  AND c.value_in_use = 0

UNION ALL

-- (4) Backup compression default = 0 — backups are larger and slower by default.
SELECT
    'Configuration'                                         AS dimension,
    NULL                                                    AS database_name,
    '(instance)'                                            AS object_name,
    'Low'                                                   AS severity,
    'backup compression default = ' || c.value_in_use       AS metric,
    'Backup compression is not on by default.'              AS finding,
    'Enable backup compression default (or set COMPRESSION per backup) to shrink backup size and shorten backup/restore time. [CONFIG CHANGE]' AS recommendation,
    'Compressed backups are typically far smaller and faster to write/restore for a modest CPU cost — a near-universal win.' AS why,
    'sqlserver-infrastructure'                              AS consult_skill
FROM config c
WHERE c.config_name = 'backup compression default'
  AND c.value_in_use = 0
;
