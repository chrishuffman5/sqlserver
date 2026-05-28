/*******************************************************************************
 * SQL Server Infrastructure - Instance Configuration Audit
 *
 * Purpose : Compare current sp_configure / sys.configurations values against
 *           recommended infrastructure baselines and flag deviations and any
 *           settings that are set but not yet active (value <> value_in_use
 *           = pending RECONFIGURE / restart).
 * Version : 1.0.0
 * Targets : SQL Server 2016+ (13.x) on Windows/Linux. Box product.
 *           On Azure SQL DB most settings do not exist (EngineEdition 5).
 * Safety  : READ-ONLY. No data or configuration is modified. Recommended
 *           changes are shown only as COMMENTED-OUT templates.
 *
 * Sections:
 *   1. Key configuration vs recommended (with pending-change flag)
 *   2. All non-default advanced settings (full picture)
 *   3. Commented remediation template
 ******************************************************************************/
SET NOCOUNT ON;

/*──────────────────────────────────────────────────────────────────────────────
  Section 1: Key configuration vs recommended baseline
  - value          = configured (requested) value
  - value_in_use   = value the engine is actually running with
  - value <> value_in_use  ⇒ pending RECONFIGURE (dynamic) or restart (static)
──────────────────────────────────────────────────────────────────────────────*/
DECLARE @physical_mb BIGINT =
    (SELECT total_physical_memory_kb / 1024 FROM sys.dm_os_sys_memory);

SELECT
    c.name                                              AS setting,
    c.value                                             AS configured_value,
    c.value_in_use                                      AS running_value,
    CASE WHEN c.value <> c.value_in_use
         THEN 'PENDING - RECONFIGURE or restart required'
         ELSE 'active' END                              AS apply_state,
    c.is_advanced,
    c.is_dynamic,                                       -- 1 = no restart needed
    CASE c.name
        WHEN 'max server memory (MB)'           THEN 'RAM minus OS reservation (formula). Not 2147483647.'
        WHEN 'min server memory (MB)'           THEN '0 on dedicated box; floor only on shared boxes.'
        WHEN 'cost threshold for parallelism'   THEN 'Raise from 5 to ~50, then tune.'
        WHEN 'max degree of parallelism'        THEN 'Physical cores per NUMA node, cap 8 (OLTP often 1-8).'
        WHEN 'optimize for ad hoc workloads'    THEN 'Set to 1 - caches plan stub, curbs cache bloat.'
        WHEN 'backup compression default'       THEN 'Set to 1 (Standard+ 2016 SP1+).'
        WHEN 'max worker threads'               THEN 'Leave 0 (auto) unless strong THREADPOOL evidence.'
        WHEN 'remote admin connections'         THEN 'Leave 0; local DAC always works. Set 1 only for documented break-glass, then firewall to jump hosts + audit.'
        WHEN 'blocked process threshold (s)'    THEN '5-20s with an XEvent capture; 0 = off.'
        WHEN 'priority boost'                   THEN 'MUST be 0. Never enable.'
        WHEN 'lightweight pooling'              THEN 'MUST be 0. Fiber mode breaks CLR/linked servers.'
        WHEN 'fill factor (%)'                  THEN 'Leave 0 (=100); set fill factor per-index.'
        ELSE ''
    END                                                 AS recommendation,
    CASE
        WHEN c.name = 'max server memory (MB)'        AND c.value_in_use > @physical_mb       THEN 'DEVIATION - exceeds physical RAM'
        WHEN c.name = 'max server memory (MB)'        AND c.value_in_use = 2147483647         THEN 'DEVIATION - unlimited (default)'
        WHEN c.name = 'cost threshold for parallelism' AND c.value_in_use <= 5                THEN 'DEVIATION - default 5 is too low'
        WHEN c.name = 'max degree of parallelism'     AND c.value_in_use = 0                  THEN 'REVIEW - 0/unlimited; check NUMA cores'
        WHEN c.name = 'optimize for ad hoc workloads' AND c.value_in_use = 0                  THEN 'DEVIATION - recommend 1'
        WHEN c.name = 'backup compression default'    AND c.value_in_use = 0                  THEN 'DEVIATION - recommend 1'
        WHEN c.name = 'priority boost'                AND c.value_in_use = 1                  THEN 'CRITICAL - disable immediately'
        WHEN c.name = 'lightweight pooling'           AND c.value_in_use = 1                  THEN 'CRITICAL - disable'
        WHEN c.name = 'remote admin connections'      AND c.value_in_use = 1                  THEN 'REVIEW - remote DAC enabled; confirm break-glass justification, firewall + audit'
        ELSE 'ok / review'
    END                                                 AS deviation_flag
FROM sys.configurations AS c
WHERE c.name IN (
    'max server memory (MB)', 'min server memory (MB)',
    'cost threshold for parallelism', 'max degree of parallelism',
    'optimize for ad hoc workloads', 'backup compression default',
    'max worker threads', 'remote admin connections',
    'blocked process threshold (s)', 'priority boost',
    'lightweight pooling', 'fill factor (%)'
)
ORDER BY c.name;

/*──────────────────────────────────────────────────────────────────────────────
  Section 2: All settings whose configured value differs from the SQL default
  Gives the full picture beyond the curated list above.
──────────────────────────────────────────────────────────────────────────────*/
SELECT
    name                AS setting,
    value               AS configured_value,
    value_in_use        AS running_value,
    minimum, maximum,
    is_advanced,
    is_dynamic,
    CASE WHEN value <> value_in_use
         THEN 'PENDING' ELSE 'active' END AS apply_state
FROM sys.configurations
ORDER BY is_advanced, name;

/*──────────────────────────────────────────────────────────────────────────────
  Section 3: Remediation template (COMMENTED OUT - review before running)
  Replace 49152 with your computed max server memory; MAXDOP with cores/NUMA.
──────────────────────────────────────────────────────────────────────────────*/
/*
EXEC sp_configure 'show advanced options', 1; RECONFIGURE;
EXEC sp_configure 'max server memory (MB)', 49152;        RECONFIGURE;  -- formula: RAM - OS - (RAM-16)/4
EXEC sp_configure 'min server memory (MB)', 0;            RECONFIGURE;
EXEC sp_configure 'cost threshold for parallelism', 50;   RECONFIGURE;
EXEC sp_configure 'max degree of parallelism', 8;         RECONFIGURE;  -- physical cores per NUMA node, cap 8
EXEC sp_configure 'optimize for ad hoc workloads', 1;     RECONFIGURE;
EXEC sp_configure 'backup compression default', 1;        RECONFIGURE;
EXEC sp_configure 'remote admin connections', 0;          RECONFIGURE;  -- leave OFF; local DAC always works. Set 1 only for documented break-glass, then firewall to jump hosts + audit
EXEC sp_configure 'blocked process threshold', 15;        RECONFIGURE;
EXEC sp_configure 'priority boost', 0;                    RECONFIGURE;  -- restart to change if it was on
EXEC sp_configure 'lightweight pooling', 0;               RECONFIGURE;  -- restart to change if it was on
*/
