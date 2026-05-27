/*******************************************************************************
 * SQL Server Monitoring - Deadlock Extraction
 *
 * Purpose : Extract recent deadlock graphs (xml_deadlock_report) from the
 *           always-on system_health Extended Events session. STEP 3 follow-up:
 *           deadlocks are LCK_* events that already happened - read the graph.
 * Version : 1.0.0
 * Targets : SQL Server 2016-2025 (box), Managed Instance. On Azure SQL Database
 *           use the database-scoped system_health-equivalent / ring buffer.
 * Safety  : Read-only. No modifications.
 *
 * Notes   : system_health uses a ROLLING ring buffer + file target, so it only
 *           retains recent deadlocks. For durable history, stand up a dedicated
 *           event_file session (see references/extended-events-and-counters.md)
 *           and read it via sys.fn_xe_file_target_read_file (Section 3 below).
 *
 * Sections:
 *   1. Deadlock Count Currently in the Ring Buffer
 *   2. Deadlock Graphs from system_health (ring buffer)
 *   3. (Optional) Deadlock Graphs from a Dedicated .xel File Target
 ******************************************************************************/
SET NOCOUNT ON;

/*──────────────────────────────────────────────────────────────────────────────
  Prerequisite: confirm system_health is running
──────────────────────────────────────────────────────────────────────────────*/
IF NOT EXISTS (SELECT 1 FROM sys.dm_xe_sessions WHERE name = N'system_health')
BEGIN
    SELECT 'The system_health Extended Events session is not running on this instance.' AS info_message;
END;

/*──────────────────────────────────────────────────────────────────────────────
  Section 1: Deadlock Count Currently in the Ring Buffer
──────────────────────────────────────────────────────────────────────────────*/
IF EXISTS (SELECT 1 FROM sys.dm_xe_sessions WHERE name = N'system_health')
BEGIN
    ;WITH sh AS
    (
        SELECT CAST(t.target_data AS XML) AS target_xml
        FROM sys.dm_xe_sessions AS s
        JOIN sys.dm_xe_session_targets AS t ON s.address = t.event_session_address
        WHERE s.name = N'system_health'
          AND t.target_name = N'ring_buffer'
    )
    SELECT
        target_xml.value('count(RingBufferTarget/event[@name="xml_deadlock_report"])', 'int')
            AS deadlocks_in_ring_buffer
    FROM sh;
END;

/*──────────────────────────────────────────────────────────────────────────────
  Section 2: Deadlock Graphs from system_health (ring buffer)
  Open the deadlock_graph XML column in SSMS to view it visually.
──────────────────────────────────────────────────────────────────────────────*/
IF EXISTS (SELECT 1 FROM sys.dm_xe_sessions WHERE name = N'system_health')
BEGIN
    ;WITH sh AS
    (
        SELECT CAST(t.target_data AS XML) AS target_xml
        FROM sys.dm_xe_sessions AS s
        JOIN sys.dm_xe_session_targets AS t ON s.address = t.event_session_address
        WHERE s.name = N'system_health'
          AND t.target_name = N'ring_buffer'
    )
    SELECT
        x.dl.value('(event/@timestamp)[1]', 'DATETIME2')                      AS deadlock_time_utc,
        x.dl.value('(event/data[@name="xml_report"]/value/deadlock/victim-list/victimProcess/@id)[1]', 'VARCHAR(50)') AS victim_process_id,
        x.dl.query('(event/data[@name="xml_report"]/value/deadlock)[1]')      AS deadlock_graph
    FROM sh
    CROSS APPLY target_xml.nodes('RingBufferTarget/event[@name="xml_deadlock_report"]') AS x(dl)
    ORDER BY deadlock_time_utc DESC;
END;

/*──────────────────────────────────────────────────────────────────────────────
  Section 3: (Optional) Deadlock Graphs from a Dedicated .xel File Target
  Uncomment and set the path/filename of a dedicated deadlock-capture session.
  This is the durable source when system_health has rolled over.
──────────────────────────────────────────────────────────────────────────────*/
/*
SELECT
    CONVERT(XML, event_data).value('(event/@timestamp)[1]', 'DATETIME2')      AS deadlock_time_utc,
    CONVERT(XML, event_data).query('(event/data[@name="xml_report"]/value/deadlock)[1]') AS deadlock_graph
FROM sys.fn_xe_file_target_read_file(N'DeadlockCapture*.xel', NULL, NULL, NULL)
WHERE object_name = N'xml_deadlock_report'
ORDER BY deadlock_time_utc DESC;
*/

-- How to read the graph:
--   * victim-list  -> the session SQL Server chose to kill (lowest rollback cost)
--   * resource-list-> the objects/keys/pages the processes deadlocked on
--   * process-list -> each process's input buffer, isolation level, and lock requested
-- Typical fixes: consistent lock ordering, shorter transactions, a covering index
-- to avoid the lookup that took the second lock, or RCSI to remove reader/writer cycles.
