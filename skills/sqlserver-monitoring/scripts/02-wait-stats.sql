/*******************************************************************************
 * SQL Server Monitoring - Wait Statistics Analysis
 *
 * Purpose : Identify the top waits causing performance bottlenecks since the
 *           last restart, with a comprehensive benign-wait filter. This is
 *           STEP 1 of the diagnostic workflow - start here, then drill down.
 * Version : 1.0.0
 * Targets : SQL Server 2016-2025 (box) and Managed Instance. On Azure SQL
 *           Database use sys.dm_db_wait_stats (see note in Section 1).
 * Safety  : Read-only. No modifications. Does NOT clear wait stats
 *           (DBCC SQLPERF(...,CLEAR) is destructive and intentionally omitted).
 *
 * Sections:
 *   1. Top Waits by Cumulative Wait Time (Filtered, with Running %)
 *   2. Overall Signal vs Resource Wait Ratio (CPU-Pressure Indicator)
 *   3. Wait Category Breakdown
 *   4. Current In-Progress Waits (Live)
 ******************************************************************************/
SET NOCOUNT ON;

/*──────────────────────────────────────────────────────────────────────────────
  Section 1: Top Waits by Cumulative Wait Time
  Filters out benign / idle waits that would otherwise drown the signal.
  NOTE: On Azure SQL Database replace sys.dm_os_wait_stats with
        sys.dm_db_wait_stats (instance view is not exposed there).
──────────────────────────────────────────────────────────────────────────────*/
;WITH filtered_waits AS
(
    SELECT
        wait_type,
        waiting_tasks_count,
        wait_time_ms,
        max_wait_time_ms,
        signal_wait_time_ms,
        wait_time_ms - signal_wait_time_ms              AS resource_wait_time_ms
    FROM sys.dm_os_wait_stats
    WHERE wait_type NOT IN
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
    AND waiting_tasks_count > 0
),
total AS
(
    SELECT SUM(wait_time_ms) AS total_wait_time_ms FROM filtered_waits
)
SELECT TOP (25)
    fw.wait_type,
    fw.waiting_tasks_count                              AS wait_count,
    fw.wait_time_ms                                     AS total_wait_ms,
    fw.resource_wait_time_ms                            AS resource_wait_ms,
    fw.signal_wait_time_ms                              AS signal_wait_ms,
    CAST(fw.wait_time_ms * 1.0
        / NULLIF(fw.waiting_tasks_count, 0) AS DECIMAL(18,2)) AS avg_wait_ms,
    fw.max_wait_time_ms                                 AS max_wait_ms,
    CAST(fw.wait_time_ms * 100.0
        / NULLIF(t.total_wait_time_ms, 0) AS DECIMAL(5,2))    AS pct_of_total,
    CAST(fw.signal_wait_time_ms * 100.0
        / NULLIF(fw.wait_time_ms, 0) AS DECIMAL(5,2))         AS signal_pct,
    -- Pareto: running cumulative percentage of the top waits
    CAST(SUM(fw.wait_time_ms) OVER (ORDER BY fw.wait_time_ms DESC) * 100.0
        / NULLIF(t.total_wait_time_ms, 0) AS DECIMAL(5,2))    AS running_pct
FROM filtered_waits AS fw
CROSS JOIN total AS t
ORDER BY fw.wait_time_ms DESC;

/*──────────────────────────────────────────────────────────────────────────────
  Section 2: Overall Signal vs Resource Wait Ratio
  A high signal_wait_pct (rule of thumb > ~25%) indicates CPU/scheduler pressure:
  tasks are runnable but waiting for a CPU.
──────────────────────────────────────────────────────────────────────────────*/
SELECT
    CAST(100.0 * SUM(signal_wait_time_ms)
        / NULLIF(SUM(wait_time_ms), 0) AS DECIMAL(5,2))       AS signal_wait_pct,
    CAST(100.0 * SUM(wait_time_ms - signal_wait_time_ms)
        / NULLIF(SUM(wait_time_ms), 0) AS DECIMAL(5,2))       AS resource_wait_pct
FROM sys.dm_os_wait_stats
WHERE waiting_tasks_count > 0;

/*──────────────────────────────────────────────────────────────────────────────
  Section 3: Wait Category Breakdown
  Groups raw wait types into human-readable categories for quick triage.
──────────────────────────────────────────────────────────────────────────────*/
;WITH categorized_waits AS
(
    SELECT
        CASE
            WHEN wait_type LIKE N'LCK_%'                    THEN 'Lock'
            WHEN wait_type LIKE N'PAGEIOLATCH_%'            THEN 'Buffer I/O (disk)'
            WHEN wait_type LIKE N'PAGELATCH_%'              THEN 'Buffer Latch (memory)'
            WHEN wait_type LIKE N'LATCH_%'                  THEN 'Non-buffer Latch'
            WHEN wait_type LIKE N'HADR_%'                   THEN 'Availability Group'
            WHEN wait_type LIKE N'PREEMPTIVE_%'             THEN 'Preemptive (External)'
            WHEN wait_type IN (N'ASYNC_NETWORK_IO',
                               N'NET_WAITFOR_PACKET')       THEN 'Network'
            WHEN wait_type IN (N'CXPACKET', N'CXCONSUMER',
                               N'CXSYNC_PORT', N'CXSYNC_CONSUMER') THEN 'Parallelism'
            WHEN wait_type IN (N'RESOURCE_SEMAPHORE',
                               N'RESOURCE_SEMAPHORE_QUERY_COMPILE',
                               N'CMEMTHREAD')               THEN 'Memory'
            WHEN wait_type IN (N'WRITELOG', N'LOGBUFFER')
              OR wait_type LIKE N'LOGMGR%'                  THEN 'Transaction Log'
            WHEN wait_type IN (N'SOS_SCHEDULER_YIELD',
                               N'THREADPOOL')               THEN 'CPU / Scheduler'
            WHEN wait_type IN (N'IO_COMPLETION',
                               N'ASYNC_IO_COMPLETION',
                               N'BACKUPIO', N'BACKUPBUFFER') THEN 'Disk I/O (non-buffer)'
            ELSE 'Other'
        END                                             AS wait_category,
        wait_time_ms,
        waiting_tasks_count,
        signal_wait_time_ms
    FROM sys.dm_os_wait_stats
    WHERE waiting_tasks_count > 0
)
SELECT
    wait_category,
    SUM(waiting_tasks_count)                            AS total_wait_count,
    SUM(wait_time_ms)                                   AS total_wait_ms,
    SUM(signal_wait_time_ms)                            AS total_signal_ms,
    SUM(wait_time_ms) - SUM(signal_wait_time_ms)        AS total_resource_ms
FROM categorized_waits
GROUP BY wait_category
ORDER BY total_wait_ms DESC;

/*──────────────────────────────────────────────────────────────────────────────
  Section 4: Current In-Progress Waits (Live)
  The live counterpart of the cumulative stats above.
──────────────────────────────────────────────────────────────────────────────*/
SELECT TOP (50)
    owt.session_id,
    owt.exec_context_id,
    owt.wait_type,
    owt.wait_duration_ms,
    owt.blocking_session_id,
    owt.resource_description,
    es.login_name,
    es.host_name,
    es.program_name,
    er.command,
    er.status                                           AS request_status,
    DB_NAME(er.database_id)                             AS database_name
FROM sys.dm_os_waiting_tasks AS owt
INNER JOIN sys.dm_exec_sessions AS es
    ON owt.session_id = es.session_id
LEFT JOIN sys.dm_exec_requests AS er
    ON owt.session_id = er.session_id
WHERE owt.session_id > 50          -- exclude system SPIDs
  AND owt.session_id <> @@SPID
ORDER BY owt.wait_duration_ms DESC;
