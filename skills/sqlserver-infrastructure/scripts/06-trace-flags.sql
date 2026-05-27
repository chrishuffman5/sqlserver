/*******************************************************************************
 * SQL Server Infrastructure - Global Trace Flags
 *
 * Purpose : Capture the active GLOBAL trace flags (DBCC TRACESTATUS(-1)) into a
 *           temp table and report them alongside a reference list of common
 *           flags and their meaning / modern status (many became default or
 *           moved to database-scoped configuration).
 * Version : 1.0.0
 * Targets : SQL Server 2016+ (13.x) on Windows/Linux. Box product.
 * Safety  : READ-ONLY. DBCC TRACESTATUS only reports; no flags are changed.
 *           Enabling flags is shown only as a COMMENTED-OUT template.
 *
 * Sections:
 *   1. Active global trace flags
 *   2. Common trace-flag reference (commented)
 ******************************************************************************/
SET NOCOUNT ON;

/*──────────────────────────────────────────────────────────────────────────────
  Section 1: Active global trace flags
  DBCC TRACESTATUS(-1) returns only the GLOBALLY enabled flags.
──────────────────────────────────────────────────────────────────────────────*/
IF OBJECT_ID('tempdb..#trace_flags') IS NOT NULL DROP TABLE #trace_flags;
CREATE TABLE #trace_flags
(
    TraceFlag INT     NOT NULL,
    Status    TINYINT NOT NULL,   -- 1 = enabled
    Global    TINYINT NOT NULL,   -- 1 = global
    Session   TINYINT NOT NULL    -- 1 = session-scoped
);

INSERT INTO #trace_flags (TraceFlag, Status, Global, Session)
EXEC ('DBCC TRACESTATUS(-1) WITH NO_INFOMSGS');

IF EXISTS (SELECT 1 FROM #trace_flags)
BEGIN
    SELECT
        tf.TraceFlag,
        tf.Status                                        AS is_enabled,
        tf.Global                                        AS is_global,
        tf.Session                                       AS is_session,
        CASE tf.TraceFlag
            WHEN 1117 THEN 'Grow all files in a filegroup together (default for tempdb 2016+)'
            WHEN 1118 THEN 'Uniform extent allocation (default for tempdb 2016+)'
            WHEN 3226 THEN 'Suppress successful-backup messages in error log (safe, common)'
            WHEN 1222 THEN 'Deadlock graph to error log (prefer system_health XEvent)'
            WHEN 1204 THEN 'Deadlock info to error log (older text format)'
            WHEN 4199 THEN 'Query-optimizer hotfixes (now per-DB QUERY_OPTIMIZER_HOTFIXES, 2016+)'
            WHEN 7412 THEN 'Lightweight query profiling (ON by default 2019+)'
            WHEN  460 THEN 'Detailed string-truncation error 2628 (default 2019+)'
            WHEN 3625 THEN 'Limited mode - hide details from non-sysadmins (hardening)'
            WHEN 8048 THEN 'NUMA-partitioned -> CPU-partitioned memory objects (legacy spinlock relief)'
            WHEN  834 THEN 'Large-page buffer-pool allocations (Enterprise + LPIM; specialist)'
            WHEN 1806 THEN 'DISABLES Instant File Initialization (diagnostic only)'
            ELSE 'See documentation - not in the common reference list'
        END                                              AS meaning
    FROM #trace_flags AS tf
    ORDER BY tf.TraceFlag;
END
ELSE
BEGIN
    SELECT 'No global trace flags are currently enabled.' AS info_message;
END;

DROP TABLE #trace_flags;

/*──────────────────────────────────────────────────────────────────────────────
  Section 2: Common trace-flag reference & how to set durably (COMMENTED OUT)

  Prefer the MODERN mechanism where one exists:
    - tempdb uniform extents / grow-all (1117/1118)  -> built in for tempdb 2016+
    - optimizer hotfixes (4199)                       -> DSC QUERY_OPTIMIZER_HOTFIXES
    - deadlock capture (1222/1204)                    -> system_health XEvent session

  Enable a flag GLOBALLY for the current uptime only (lost on restart):
      -- DBCC TRACEON (3226, -1);

  Make it DURABLE: add it as a -T startup parameter
      Windows : SQL Server Configuration Manager -> service -> Startup Parameters -> add  -T3226
      Linux   : sudo /opt/mssql/bin/mssql-conf traceflag 3226 on  (then restart mssql-server)
──────────────────────────────────────────────────────────────────────────────*/
