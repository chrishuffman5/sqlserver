/*******************************************************************************
 * SQL Server Advisor - Collector 12: Wait Statistics
 *
 * Purpose : Capture the top waits since instance restart with the standard
 *           benign/idle wait filter and each wait's share of total wait time.
 *           Feeds the cross-cutting Configuration / bottleneck context in the
 *           advisor (e.g. CXPACKET -> cost threshold; PAGEIOLATCH -> I/O or
 *           missing-index pressure; WRITELOG -> log latency).
 * Version : 1.0.0
 * Targets : SQL Server 2016-2025 (box / Azure VM / MI). On Azure SQL Database
 *           sys.dm_os_wait_stats is scoped to the database/replica; use
 *           sys.dm_db_wait_stats there for a true per-DB view (see note).
 * Safety  : READ-ONLY. Reads sys.dm_os_wait_stats only. Does NOT clear waits
 *           (DBCC SQLPERF(...,CLEAR) is destructive and intentionally omitted).
 *
 * Output columns (EXACT capture contract -> capture/wait_stats.csv):
 *   server_name, captured_at, wait_type, waiting_tasks_count, wait_time_ms,
 *   signal_wait_time_ms, pct_of_total
 *
 * Notes:
 *   - These counters are CUMULATIVE SINCE RESTART. pct_of_total is computed
 *     across the FILTERED (non-benign) set so a single window's signal is not
 *     drowned by idle waits. Correlate against server_info.sqlserver_start_time
 *     to judge whether the window is representative.
 *   - The benign-wait filter mirrors the comprehensive list used by
 *     sqlserver-monitoring/scripts/02-wait-stats.sql.
 *   - Top 50 captured (more than the live triage view) so DuckDB can trend a
 *     broader set across multiple capture runs.
 ******************************************************************************/
SET NOCOUNT ON;

;WITH filtered_waits AS
(
    SELECT
        wait_type,
        waiting_tasks_count,
        wait_time_ms,
        signal_wait_time_ms
    FROM sys.dm_os_wait_stats
    WHERE waiting_tasks_count > 0
      AND wait_type NOT IN
      (
        -- Sleeping / idle background waits
        N'SLEEP_TASK',                       N'SLEEP_SYSTEMTASK',
        N'SLEEP_BPOOL_FLUSH',                N'SLEEP_DBSTARTUP',
        N'SLEEP_DCOMSTARTUP',                N'SLEEP_MASTERDBREADY',
        N'SLEEP_MASTERMDREADY',              N'SLEEP_MASTERUPGRADED',
        N'SLEEP_MSDBSTARTUP',                N'SLEEP_TEMPDBSTARTUP',
        N'LAZYWRITER_SLEEP',                 N'WAITFOR',
        N'WAITFOR_TASKSHUTDOWN',             N'WAIT_FOR_RESULTS',
        N'SERVER_IDLE_CHECK',                N'KSOURCE_WAKEUP',
        -- Checkpoint / log housekeeping
        N'CHECKPOINT_QUEUE',                 N'CHKPT',
        N'LOGMGR_QUEUE',                     N'DIRTY_PAGE_POLL',
        N'REDO_THREAD_PENDING_WORK',
        -- Service Broker idle loops
        N'BROKER_EVENTHANDLER',              N'BROKER_RECEIVE_WAITFOR',
        N'BROKER_TASK_STOP',                 N'BROKER_TO_FLUSH',
        N'BROKER_TRANSMITTER',
        -- CLR / dispatcher / XE idle
        N'CLR_AUTO_EVENT',                   N'CLR_MANUAL_EVENT',
        N'CLR_SEMAPHORE',                    N'DISPATCHER_QUEUE_SEMAPHORE',
        N'ONDEMAND_TASK_QUEUE',              N'SOS_WORK_DISPATCHER',
        N'XE_DISPATCHER_JOIN',               N'XE_DISPATCHER_WAIT',
        N'XE_TIMER_EVENT',                   N'XE_BUFFERMGR_ALLPROCESSED_EVENT',
        N'XE_LIVE_TARGET_TVF',
        -- Full-text idle
        N'FT_IFTS_SCHEDULER_IDLE_WAIT',      N'FT_IFTSHC_MUTEX',
        N'FSAGENT',
        -- Database mirroring idle
        N'DBMIRROR_DBM_EVENT',               N'DBMIRROR_EVENTS_QUEUE',
        N'DBMIRROR_WORKER_QUEUE',            N'DBMIRRORING_CMD',
        -- Always On / HADR idle & redo housekeeping
        N'HADR_CLUSAPI_CALL',                N'HADR_FILESTREAM_IOMGR_IOCOMPLETION',
        N'HADR_LOGCAPTURE_WAIT',             N'HADR_NOTIFICATION_DEQUEUE',
        N'HADR_TIMER_TASK',                  N'HADR_WORK_QUEUE',
        N'PARALLEL_REDO_DRAIN_WORKER',       N'PARALLEL_REDO_LOG_CACHE',
        N'PARALLEL_REDO_TRAN_LIST',          N'PARALLEL_REDO_WORKER_SYNC',
        N'PARALLEL_REDO_WORKER_WAIT_WORK',
        -- Query Store background tasks
        N'QDS_PERSIST_TASK_MAIN_LOOP_SLEEP', N'QDS_ASYNC_QUEUE',
        N'QDS_CLEANUP_STALE_QUERIES_TASK_MAIN_LOOP_SLEEP',
        N'QDS_SHUTDOWN_QUEUE',
        -- In-Memory OLTP (XTP) housekeeping
        N'WAIT_XTP_CKPT_CLOSE',              N'WAIT_XTP_HOST_WAIT',
        N'WAIT_XTP_OFFLINE_CKPT_NEW_LOG',    N'WAIT_XTP_RECOVERY',
        -- Diagnostics / trace / misc idle
        N'SP_SERVER_DIAGNOSTICS_SLEEP',      N'SQLTRACE_BUFFER_FLUSH',
        N'SQLTRACE_INCREMENTAL_FLUSH_SLEEP', N'SQLTRACE_WAIT_ENTRIES',
        N'REQUEST_FOR_DEADLOCK_SEARCH',      N'RESOURCE_QUEUE',
        N'EXECSYNC',                         N'SNI_HTTP_ACCEPT',
        N'PWAIT_ALL_COMPONENTS_INITIALIZED', N'PWAIT_DIRECTLOGCONSUMER_GETNEXT',
        N'VDI_CLIENT_OTHER',                 N'MEMORY_ALLOCATION_EXT',
        N'PVS_PREALLOCATE',                  N'PREEMPTIVE_XE_GETTARGETSTATE',
        N'PREEMPTIVE_OS_FLUSHFILEBUFFERS',   N'PREEMPTIVE_OS_AUTHENTICATIONOPS',
        N'PREEMPTIVE_OS_GETPROCADDRESS'
      )
),
total AS
(
    SELECT SUM(wait_time_ms) AS total_wait_time_ms FROM filtered_waits
)
SELECT TOP (50)
    CONVERT(varchar(256), SERVERPROPERTY('ServerName'))  AS server_name,
    SYSUTCDATETIME()                                     AS captured_at,
    fw.wait_type                                         AS wait_type,
    fw.waiting_tasks_count                               AS waiting_tasks_count,
    fw.wait_time_ms                                      AS wait_time_ms,
    fw.signal_wait_time_ms                               AS signal_wait_time_ms,
    CAST(fw.wait_time_ms * 100.0
         / NULLIF(t.total_wait_time_ms, 0) AS DECIMAL(5,2)) AS pct_of_total
FROM filtered_waits AS fw
CROSS JOIN total AS t
ORDER BY fw.wait_time_ms DESC;
