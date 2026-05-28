-- =====================================================================
-- a11-db-settings.sql  —  database-level statistics & configuration hygiene
-- ---------------------------------------------------------------------
-- PREREQUISITE: run analysis/00-load.sql first.
-- Consumes the db_inventory capture (the per-database settings that no other
-- analyzer reads) and emits the unified findings shape:
--   dimension in ('Statistics','Configuration'), database_name, object_name,
--   severity, metric, finding, recommendation, why, consult_skill
-- Scope: user databases only (database_id > 4) so the system DBs are not flagged.
-- All recommendations are ADVISORY; several (RCSI, compat level) are deliberate,
-- workload-dependent changes — validate in non-prod and follow consult_skill.
-- =====================================================================

-- Statistics: auto-update off
SELECT 'Statistics' AS dimension, d.database_name,
       '(database) ' || d.database_name AS object_name,
       'Medium' AS severity,
       'is_auto_update_stats_on=' || d.is_auto_update_stats_on AS metric,
       'Auto-update statistics is disabled.' AS finding,
       'Enable AUTO_UPDATE_STATISTICS unless a controlled manual-stats regime (e.g. Ola/Agent jobs) fully covers it. [CONFIG CHANGE]' AS recommendation,
       'With auto-update off, the optimizer estimates from stale cardinality and produces progressively worse plans as data drifts.' AS why,
       'sqlserver-operations' AS consult_skill
FROM db_inventory d WHERE d.database_id > 4 AND d.is_auto_update_stats_on = FALSE

UNION ALL
-- Statistics: auto-create off
SELECT 'Statistics', d.database_name, '(database) ' || d.database_name, 'Medium',
       'is_auto_create_stats_on=' || d.is_auto_create_stats_on,
       'Auto-create statistics is disabled.',
       'Enable AUTO_CREATE_STATISTICS so the optimizer can build the single-column stats it needs for estimates. [CONFIG CHANGE]',
       'Without auto-create, predicates on un-stat''d columns get guessed selectivity, risking bad join orders and scans.',
       'sqlserver-operations'
FROM db_inventory d WHERE d.database_id > 4 AND d.is_auto_create_stats_on = FALSE

UNION ALL
-- Statistics: synchronous auto-update on a large/OLTP database (latency risk)
SELECT 'Statistics', d.database_name, '(database) ' || d.database_name, 'Low',
       'async_update=' || d.is_auto_update_stats_async_on || '; size=' || d.total_size_mb || ' MB',
       'Auto-update statistics is synchronous (async disabled) on a sizable database.',
       'Consider AUTO_UPDATE_STATISTICS_ASYNC = ON for OLTP so a stats refresh does not stall the triggering query. [CONFIG CHANGE]',
       'Synchronous auto-update makes the unlucky query wait for the stats rebuild; async lets it run on the old stats while the refresh happens in the background.',
       'sqlserver-operations'
FROM db_inventory d WHERE d.database_id > 4 AND d.is_auto_update_stats_on = TRUE
      AND d.is_auto_update_stats_async_on = FALSE AND d.total_size_mb >= 10240

UNION ALL
-- Configuration: page_verify not CHECKSUM
SELECT 'Configuration', d.database_name, '(database) ' || d.database_name, 'Medium',
       'page_verify=' || COALESCE(d.page_verify_option_desc,'NONE'),
       'PAGE_VERIFY is not CHECKSUM.',
       'Set PAGE_VERIFY CHECKSUM so torn pages / I/O bit-rot are detected on read; pair with regular DBCC CHECKDB. [CONFIG CHANGE]',
       'TORN_PAGE_DETECTION and NONE miss most storage corruption; CHECKSUM is the modern default and the cheapest early-warning signal.',
       'sqlserver-operations'
FROM db_inventory d WHERE d.database_id > 4 AND COALESCE(d.page_verify_option_desc,'NONE') <> 'CHECKSUM'

UNION ALL
-- Configuration: RCSI disabled (advisory, workload-dependent)
SELECT 'Configuration', d.database_name, '(database) ' || d.database_name, 'Low',
       'is_read_committed_snapshot_on=' || d.is_read_committed_snapshot_on,
       'READ_COMMITTED_SNAPSHOT (RCSI) is disabled.',
       'For read-heavy OLTP, evaluate enabling RCSI to cut reader/writer blocking (size the tempdb version store first; needs exclusive DB access to switch). [CONFIG CHANGE]',
       'Default READ COMMITTED takes shared locks that block under write contention; RCSI serves a row version instead — a deliberate, workload-dependent trade for tempdb pressure.',
       'sqlserver-engineering'
FROM db_inventory d WHERE d.database_id > 4 AND d.is_read_committed_snapshot_on = FALSE

UNION ALL
-- Configuration: old compatibility level
SELECT 'Configuration', d.database_name, '(database) ' || d.database_name, 'Low',
       'compatibility_level=' || d.compatibility_level,
       'Database is on an older compatibility level.',
       'Plan an upgrade to a current compatibility level behind Query Store (capture a baseline, watch for plan regressions); do not bump it blind. [CONFIG CHANGE]',
       'Old compat levels lock the database out of newer optimizer/IQP behavior, but raising it can shift plans — Query Store + staged testing is the safe path.',
       'sqlserver-engineering'
FROM db_inventory d WHERE d.database_id > 4 AND d.compatibility_level < 150;
