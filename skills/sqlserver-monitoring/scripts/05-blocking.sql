/*******************************************************************************
 * SQL Server Monitoring - Blocking Analysis
 *
 * Purpose : Surface current blocking: blocked/blocker pairs and the recursive
 *           head-blocker chain. STEP 3 of the workflow when LCK_* waits appear.
 *           Resolve the HEAD blocker - victims clear themselves.
 * Version : 1.0.0
 * Targets : SQL Server 2016-2025 (box), Managed Instance, Azure SQL Database.
 * Safety  : Read-only. Reports only - never kills a session.
 *
 * Sections:
 *   1. Current Blocking Pairs (blocked vs blocker, with SQL text)
 *   2. Recursive Blocking Chain & Head Blockers
 *   3. Lock Detail for Blocked Requests
 ******************************************************************************/
SET NOCOUNT ON;

/*──────────────────────────────────────────────────────────────────────────────
  Section 1: Current Blocking Pairs
  One row per blocked request, with the blocker it is waiting on.
──────────────────────────────────────────────────────────────────────────────*/
SELECT
    blocked.session_id                                  AS blocked_session,
    blocked.blocking_session_id                         AS blocker_session,
    blocked.wait_type,
    blocked.wait_time / 1000                            AS wait_seconds,
    blocked.wait_resource,
    DB_NAME(blocked.database_id)                        AS database_name,
    blocked.command                                     AS blocked_command,
    bs.login_name                                       AS blocked_login,
    bs.host_name                                        AS blocked_host,
    bs.program_name                                     AS blocked_program,
    blocker_s.login_name                                AS blocker_login,
    blocker_s.host_name                                 AS blocker_host,
    blocker_s.program_name                              AS blocker_program,
    blocker_s.status                                    AS blocker_status,
    blocker_s.last_request_start_time                   AS blocker_last_request_start,
    SUBSTRING(blocked_text.text,
        blocked.statement_start_offset / 2 + 1,
        (CASE WHEN blocked.statement_end_offset = -1
              THEN DATALENGTH(blocked_text.text)
              ELSE blocked.statement_end_offset END
         - blocked.statement_start_offset) / 2 + 1)     AS blocked_statement,
    blocker_text.text                                   AS blocker_last_sql
FROM sys.dm_exec_requests AS blocked
JOIN sys.dm_exec_sessions AS bs        ON blocked.session_id = bs.session_id
JOIN sys.dm_exec_sessions AS blocker_s ON blocked.blocking_session_id = blocker_s.session_id
CROSS APPLY sys.dm_exec_sql_text(blocked.sql_handle)               AS blocked_text
OUTER APPLY sys.dm_exec_sql_text(blocker_s.most_recent_sql_handle) AS blocker_text
WHERE blocked.blocking_session_id <> 0
ORDER BY blocked.wait_time DESC;

/*──────────────────────────────────────────────────────────────────────────────
  Section 2: Recursive Blocking Chain & Head Blockers
  Level 0 rows are HEAD blockers (blocking others, blocked by no one). Fix these.
──────────────────────────────────────────────────────────────────────────────*/
;WITH blocking_chain AS
(
    -- Anchor: head blockers = sessions that block someone but are not blocked
    SELECT
        r.session_id,
        r.blocking_session_id,
        0                                               AS chain_level,
        CAST(r.session_id AS VARCHAR(1000))             AS chain_path
    FROM sys.dm_exec_requests AS r
    WHERE r.blocking_session_id = 0
      AND r.session_id IN (SELECT blocking_session_id
                           FROM sys.dm_exec_requests
                           WHERE blocking_session_id <> 0)

    UNION ALL

    -- Recurse to the sessions each blocker is itself blocking
    SELECT
        r.session_id,
        r.blocking_session_id,
        bc.chain_level + 1,
        CAST(bc.chain_path + ' -> ' + CAST(r.session_id AS VARCHAR(20)) AS VARCHAR(1000))
    FROM sys.dm_exec_requests AS r
    JOIN blocking_chain AS bc ON r.blocking_session_id = bc.session_id
    WHERE r.session_id <> r.blocking_session_id          -- guard self-reference
)
SELECT
    bc.chain_level,
    CASE WHEN bc.chain_level = 0 THEN 'HEAD BLOCKER' ELSE 'blocked victim' END AS role,
    bc.session_id,
    bc.blocking_session_id,
    bc.chain_path,
    s.login_name,
    s.host_name,
    s.program_name,
    s.status                                            AS session_status,
    DB_NAME(s.database_id)                              AS database_name,
    r.wait_type,
    r.wait_time / 1000                                  AS wait_seconds,
    t.text                                              AS last_sql
FROM blocking_chain AS bc
JOIN sys.dm_exec_sessions AS s ON bc.session_id = s.session_id
LEFT JOIN sys.dm_exec_requests AS r ON bc.session_id = r.session_id
OUTER APPLY sys.dm_exec_sql_text(COALESCE(r.sql_handle, s.most_recent_sql_handle)) AS t
ORDER BY bc.chain_level, bc.session_id
OPTION (MAXRECURSION 100);

/*──────────────────────────────────────────────────────────────────────────────
  Section 3: Lock Detail for Blocked Requests
  What exactly is being locked (object / mode) behind the blocking.
──────────────────────────────────────────────────────────────────────────────*/
SELECT
    tl.request_session_id                               AS session_id,
    tl.resource_type,
    tl.resource_subtype,
    DB_NAME(tl.resource_database_id)                    AS database_name,
    CASE WHEN tl.resource_type = N'OBJECT'
         THEN OBJECT_NAME(tl.resource_associated_entity_id, tl.resource_database_id)
         ELSE NULL END                                  AS object_name,
    tl.request_mode                                     AS lock_mode,
    tl.request_status                                   AS lock_status,    -- WAIT vs GRANT
    tl.resource_description
FROM sys.dm_tran_locks AS tl
WHERE tl.request_session_id IN
(
    SELECT session_id            FROM sys.dm_exec_requests WHERE blocking_session_id <> 0
    UNION
    SELECT blocking_session_id   FROM sys.dm_exec_requests WHERE blocking_session_id <> 0
)
ORDER BY tl.request_session_id, tl.request_status DESC;
