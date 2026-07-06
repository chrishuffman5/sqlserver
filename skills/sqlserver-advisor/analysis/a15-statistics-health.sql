-- =====================================================================
-- a15-statistics-health.sql  —  dimension: Statistics (per-statistic evidence)
-- PREREQUISITE: run analysis/00-load.sql first.
-- FINDS per-statistic staleness from the stats_health capture (this upgrades
-- the Statistics dimension from database-level switches in a11 to per-object
-- evidence):
--   (1) stale statistics — modification_counter beyond the engine's own
--       dynamic auto-update threshold (~ SQRT(1000 * rows) on compat 130+);
--   (2) old statistics with churn — not updated in > 90 days despite mods;
--   (3) poor sampling on a large table — histogram built from < 5% of rows;
--   (4) NORECOMPUTE — the statistic is frozen out of auto-update.
-- Depth: sqlserver-operations (stats maintenance) / sqlserver-engineering (CE).
-- NOTE: captured stats_health is bounded to rowsets >= 1000 rows. TRY_CAST
--   guards last_updated (an all-NULL date column in CSV loads as VARCHAR).
-- =====================================================================

-- (1) Stale statistics: churn beyond the engine's dynamic auto-update threshold
SELECT
    'Statistics'                                            AS dimension,
    s.database_name                                         AS database_name,
    s.schema_name || '.' || s.table_name || '.' || s.stats_name  AS object_name,
    CASE WHEN s.rows >= 1000000 AND s.modification_counter >= s.rows * 0.20
         THEN 'High' ELSE 'Medium' END                      AS severity,
    'mods=' || fmt_n(s.modification_counter) || ' vs rows=' || fmt_n(s.rows)
        || ' (threshold~' || fmt_n(GREATEST(500, sqrt(1000.0 * s.rows))) || ')'
        || '; last_updated=' || COALESCE(CAST(s.last_updated AS VARCHAR), 'NEVER')  AS metric,
    'Statistics are stale: modifications exceed the auto-update threshold.'  AS finding,
    'UPDATE STATISTICS on this object (consider FULLSCAN for skewed/large tables) and check why auto-update has not fired — async off, NORECOMPUTE, or a workload that never recompiles. [INDEX MAINTENANCE]' AS recommendation,
    'The optimizer estimates cardinality from the last histogram; churn past the threshold means estimates (and therefore plans) are drifting from reality.' AS why,
    'sqlserver-operations'                                  AS consult_skill
FROM stats_health s
WHERE s.modification_counter >= GREATEST(500, sqrt(1000.0 * s.rows))

UNION ALL
-- (2) Old statistics with churn (age signal, softer than rule 1)
SELECT
    'Statistics', s.database_name,
    s.schema_name || '.' || s.table_name || '.' || s.stats_name,
    'Low',
    'last_updated=' || CAST(s.last_updated AS VARCHAR)
        || ' (' || date_diff('day', TRY_CAST(s.last_updated AS TIMESTAMP), s.captured_at) || ' days ago)'
        || '; mods=' || fmt_n(s.modification_counter) || '; rows=' || fmt_n(s.rows),
    'Statistics have not been updated in over 90 days despite modifications.',
    'Fold this object into the regular stats-maintenance job (e.g. Ola Hallengren IndexOptimize @UpdateStatistics) rather than waiting for the auto-update threshold. [INDEX MAINTENANCE]',
    'Slow-churn tables can sit below the auto-update threshold for months while their histograms age badly — scheduled maintenance covers what auto-update misses.',
    'sqlserver-operations'
FROM stats_health s
WHERE TRY_CAST(s.last_updated AS TIMESTAMP) IS NOT NULL
  AND date_diff('day', TRY_CAST(s.last_updated AS TIMESTAMP), s.captured_at) > 90
  AND s.modification_counter > 0
  AND s.modification_counter < GREATEST(500, sqrt(1000.0 * s.rows))   -- rule (1) covers the rest

UNION ALL
-- (3) Poor sampling on a large table
SELECT
    'Statistics', s.database_name,
    s.schema_name || '.' || s.table_name || '.' || s.stats_name,
    'Low',
    'sample=' || fmt_d(s.sample_pct, 2) || '% (' || fmt_n(s.rows_sampled) || ' of '
        || fmt_n(s.rows) || ' rows)',
    'Statistics on a large table were built from a very small sample.',
    'If plans on this table misestimate, UPDATE STATISTICS ... WITH FULLSCAN (or a persisted higher sample rate, SQL 2016 SP1 CU4+) and compare estimates. [INDEX MAINTENANCE]',
    'A sub-5% sample can miss skew and produce histograms that misestimate hot values — a common root cause of bad plans on big tables.',
    'sqlserver-operations'
FROM stats_health s
WHERE s.rows >= 1000000 AND s.sample_pct IS NOT NULL AND s.sample_pct < 5

UNION ALL
-- (4) NORECOMPUTE: statistic excluded from auto-update
SELECT
    'Statistics', s.database_name,
    s.schema_name || '.' || s.table_name || '.' || s.stats_name,
    'Medium',
    'no_recompute=true; mods=' || fmt_n(s.modification_counter)
        || '; last_updated=' || COALESCE(CAST(s.last_updated AS VARCHAR), 'NEVER'),
    'Statistic is marked NORECOMPUTE (frozen out of auto-update).',
    'Confirm a manual stats job demonstrably refreshes it; otherwise re-enable auto-update (UPDATE STATISTICS without NORECOMPUTE / recreate the stat). [CONFIG CHANGE]',
    'NORECOMPUTE is only safe under a managed stats regime — without one, this statistic silently decays forever.',
    'sqlserver-operations'
FROM stats_health s
WHERE s.no_recompute = TRUE;
