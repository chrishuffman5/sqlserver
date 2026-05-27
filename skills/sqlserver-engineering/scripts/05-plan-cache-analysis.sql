/*******************************************************************************
 * SQL Server - Plan Cache Analysis
 *
 * Purpose : Summarize plan-cache reuse and ad-hoc bloat, and scan cached plan
 *           XML for engineering red flags: missing-index, implicit conversion
 *           (CONVERT_IMPLICIT), and large memory grants.
 * Version : 1.0.0
 * Targets : SQL Server 2016+ (13.x). On Azure SQL DB the plan-cache DMVs are
 *           scoped to the current database; on box/MI they are instance-wide.
 * Safety  : READ-ONLY. No cache is cleared and nothing is modified.
 *           (Recommendation: 'optimize for ad hoc workloads' is text only -
 *            apply it via sqlserver-infrastructure, not here.)
 *
 * Sections:
 *   1. Top cached plans by usecounts (reuse health)
 *   2. Single-use ad-hoc plan bloat (count + total size) with recommendation
 *   3. Cached plans containing a MissingIndex warning
 *   4. Cached plans containing CONVERT_IMPLICIT (SARGability killer)
 *   5. Cached plans with the largest memory grants
 *
 * NOTE: Scanning plan XML (sections 3-5) is CPU/memory intensive on a large
 *       cache - the TOP filters keep it bounded. Live waits/blocking are in
 *       sqlserver-monitoring; this is a design/engineering lens.
 ******************************************************************************/
SET NOCOUNT ON;

/*──────────────────────────────────────────────────────────────────────────────
  Section 1: Top Cached Plans by Reuse (usecounts)
──────────────────────────────────────────────────────────────────────────────*/
SELECT TOP (25)
    cp.objtype,
    cp.usecounts,
    cp.size_in_bytes / 1024                      AS size_kb,
    DB_NAME(qt.dbid)                             AS database_name,
    SUBSTRING(qt.text, 1, 300)                   AS query_text_sample
FROM sys.dm_exec_cached_plans AS cp
CROSS APPLY sys.dm_exec_sql_text(cp.plan_handle) AS qt
WHERE cp.cacheobjtype = 'Compiled Plan'
ORDER BY cp.usecounts DESC;

/*──────────────────────────────────────────────────────────────────────────────
  Section 2: Single-Use Ad-Hoc Plan Bloat
  Many single-use Adhoc plans waste plan-cache memory.
──────────────────────────────────────────────────────────────────────────────*/
SELECT
    COUNT(*)                                     AS single_use_adhoc_plans,
    CAST(SUM(cp.size_in_bytes) / 1024.0 / 1024 AS decimal(18,2)) AS total_size_mb,
    CASE
        WHEN SUM(cp.size_in_bytes) / 1024.0 / 1024 > 200
            THEN 'HIGH ad-hoc bloat - consider sp_configure '
               + '''optimize for ad hoc workloads'' = 1 (see sqlserver-infrastructure) '
               + 'and/or parameterize via sp_executesql.'
        ELSE 'Ad-hoc cache footprint looks acceptable.'
    END                                          AS recommendation
FROM sys.dm_exec_cached_plans AS cp
WHERE cp.cacheobjtype = 'Compiled Plan'
  AND cp.objtype = 'Adhoc'
  AND cp.usecounts = 1;

/*──────────────────────────────────────────────────────────────────────────────
  Section 3: Plans Containing a MISSING INDEX Warning
──────────────────────────────────────────────────────────────────────────────*/
;WITH XMLNAMESPACES (DEFAULT 'http://schemas.microsoft.com/sqlserver/2004/07/showplan'),
plans AS (
    SELECT TOP (200)
        qp.query_plan,
        cp.usecounts,
        SUBSTRING(qt.text, 1, 300) AS query_text_sample
    FROM sys.dm_exec_cached_plans AS cp
    CROSS APPLY sys.dm_exec_query_plan(cp.plan_handle) AS qp
    CROSS APPLY sys.dm_exec_sql_text(cp.plan_handle)   AS qt
    WHERE cp.cacheobjtype = 'Compiled Plan'
      AND qp.query_plan IS NOT NULL
      AND CAST(qp.query_plan AS nvarchar(max)) LIKE '%MissingIndexes%'
)
SELECT
    usecounts,
    query_text_sample,
    'MISSING INDEX flagged in plan - cross-check with script 02 and '
        + 'CONSOLIDATE before creating.'        AS recommendation
FROM plans
ORDER BY usecounts DESC;

/*──────────────────────────────────────────────────────────────────────────────
  Section 4: Plans Containing CONVERT_IMPLICIT (implicit conversions)
  Implicit conversion on the COLUMN side defeats index seeks (non-SARGable).
──────────────────────────────────────────────────────────────────────────────*/
SELECT TOP (50)
    cp.usecounts,
    SUBSTRING(qt.text, 1, 300)                   AS query_text_sample,
    'CONVERT_IMPLICIT present - check for data-type mismatch (e.g. varchar '
        + 'column vs nvarchar param). Match types to restore SARGability.'
                                                 AS recommendation
FROM sys.dm_exec_cached_plans AS cp
CROSS APPLY sys.dm_exec_query_plan(cp.plan_handle) AS qp
CROSS APPLY sys.dm_exec_sql_text(cp.plan_handle)   AS qt
WHERE cp.cacheobjtype = 'Compiled Plan'
  AND qp.query_plan IS NOT NULL
  AND CAST(qp.query_plan AS nvarchar(max)) LIKE '%CONVERT_IMPLICIT%'
ORDER BY cp.usecounts DESC;

/*──────────────────────────────────────────────────────────────────────────────
  Section 5: Plans with the Largest Memory Grants (compile-time estimate)
  Large grants come from Sort/Hash on big/over-estimated inputs; under-grants
  cause tempdb spills (diagnose live spills in sqlserver-monitoring).
──────────────────────────────────────────────────────────────────────────────*/
;WITH XMLNAMESPACES (DEFAULT 'http://schemas.microsoft.com/sqlserver/2004/07/showplan')
SELECT TOP (25)
    cp.usecounts,
    qp.query_plan.value('(//MemoryGrantInfo/@SerialDesiredMemory)[1]', 'bigint')
                                                 AS desired_memory_kb,
    qp.query_plan.value('(//MemoryGrantInfo/@SerialRequiredMemory)[1]', 'bigint')
                                                 AS required_memory_kb,
    SUBSTRING(qt.text, 1, 300)                   AS query_text_sample,
    'Large memory grant - verify cardinality estimates (stats/SARGability) '
        + 'before assuming the grant itself is the problem.'
                                                 AS recommendation
FROM sys.dm_exec_cached_plans AS cp
CROSS APPLY sys.dm_exec_query_plan(cp.plan_handle) AS qp
CROSS APPLY sys.dm_exec_sql_text(cp.plan_handle)   AS qt
WHERE cp.cacheobjtype = 'Compiled Plan'
  AND qp.query_plan IS NOT NULL
  AND qp.query_plan.exist('(//MemoryGrantInfo/@SerialDesiredMemory)[. > 0]') = 1
ORDER BY desired_memory_kb DESC;
