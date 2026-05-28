# Diagnostic Workflow Reference

The disciplined, repeatable way to diagnose SQL Server performance. The cardinal rule: **measure where the engine is stuck before you tune anything.** This document is the full version of the methodology summarized in `SKILL.md`.

Applies to SQL Server 2016–2025 on box (Windows/Linux/containers) and cloud. Version- and platform-specific notes are inline. Cloud-native resource telemetry lives in `sqlserver-cloud`.

---

## The Five-Step Method

```
1. Wait Statistics      -->  What CLASS of bottleneck? (CPU / I/O / lock / memory / log / network / parallel)
        |
2. Top Resource Queries -->  Which queries dominate that resource?
        |
3. Blocking Analysis    -->  Is the wait actually one session blocking another?
        |
4. Execution Plan       -->  Why is the specific query slow? (cardinality, spills, scans, sniffing)
        |
5. Configuration Review -->  Are instance/db settings amplifying the problem?
```

Each step *scopes* the next. Skipping step 1 is the most common diagnostic mistake — you end up tuning the query you happened to suspect rather than the one actually causing the pain.

### Step 1 — Waits: the entry point

`sys.dm_os_wait_stats` records, for every wait type, the cumulative number of waits and total/signal wait time **since the last service restart** (or since the counters were last cleared). It is the single highest-leverage diagnostic in the product: it turns "the database is slow" into "the engine spent 60% of its wait time on `PAGEIOLATCH_SH`," which immediately tells you to look at I/O and memory rather than CPU or locking.

### Step 2 — Top queries, *guided by the wait category*

Only after step 1 do you know how to sort. `PAGEIOLATCH`/I/O waits → sort `sys.dm_exec_query_stats` by logical/physical reads. `SOS_SCHEDULER_YIELD`/CPU → sort by worker time. `RESOURCE_SEMAPHORE` → look at memory grants. Sorting blindly by a single metric wastes effort on queries that are not the bottleneck.

### Step 3 — Blocking

`LCK_*` waits in step 1 mean blocking. Jump to the blocking workflow below and chase the head blocker.

### Step 4 — Plan

Now and only now do you open a single query's plan: estimated vs actual rows (cardinality error), spill warnings (under-granted memory), scans where seeks are expected (missing/unusable index), and implicit conversions. Deep plan reading and fixes belong to `sqlserver-engineering`.

For a query that is **still running** and you cannot wait for it to finish, `sys.dm_exec_query_profiles` exposes **live per-operator actual row counts** for the in-flight statement — the engine behind SSMS "Live Query Statistics." Compare its running `row_count` to the operator's `estimate_row_count` to catch a cardinality blow-up in real time (e.g. a nested-loop driving far more rows than estimated). It is fed by the **lightweight query profiling infrastructure**, which is **default-on in SQL Server 2019+** (and Azure SQL DB/MI). On 2016 SP1+/2017 it is opt-in: enable trace flag **7412** (instance-wide) or run a `query_thread_profile` Extended Events session; on 2019+ TF 7412 has no effect. (You can disable it per database via the `LIGHTWEIGHT_QUERY_PROFILING` database-scoped configuration. Verify version/flag details on Microsoft Learn for your build.)

### Step 5 — Configuration

Last, because it reshapes everything above: MAXDOP, cost threshold for parallelism, max/min server memory, tempdb file count, RCSI, trace flags. Changing these belongs to `sqlserver-infrastructure`; this skill only flags when a setting is the likely amplifier.

---

## Signal Wait vs Resource Wait

Every wait splits into two phases:

- **Resource wait** (`wait_time_ms - signal_wait_time_ms`) — time spent waiting for the resource itself (a page from disk, a lock to be released, a memory grant).
- **Signal wait** (`signal_wait_time_ms`) — time spent *after* the resource is available, sitting in the runnable queue waiting for a CPU scheduler to pick the task up.

**High signal wait % (rule of thumb > ~20–25% of total) indicates CPU pressure** — tasks are ready but cannot get on a scheduler. This is corroborating evidence for `SOS_SCHEDULER_YIELD` and runnable-queue depth. Low signal % with high resource time means the bottleneck is genuinely the resource (disk, lock, memory).

Compute the ratio **over the same benign/idle-wait filter** used below. Idle waits (lazy-writer/broker/XE sleeps) carry large *resource* time and almost no *signal* time, so including them deflates `signal_wait_pct` and **understates real CPU pressure**. Filter first, then take the ratio:

```sql
-- Overall signal-wait ratio across the instance (CPU-pressure indicator)
-- Filter benign/idle waits FIRST — the unfiltered ratio understates CPU pressure.
;WITH w AS
(
    SELECT signal_wait_time_ms, wait_time_ms
    FROM sys.dm_os_wait_stats
    WHERE waiting_tasks_count > 0
      AND wait_type NOT IN
      (   -- abbreviated benign list; use the comprehensive filter below for production
          N'SLEEP_TASK', N'SLEEP_SYSTEMTASK', N'LAZYWRITER_SLEEP', N'WAITFOR',
          N'XE_TIMER_EVENT', N'XE_DISPATCHER_WAIT', N'DIRTY_PAGE_POLL',
          N'CHECKPOINT_QUEUE', N'LOGMGR_QUEUE', N'REQUEST_FOR_DEADLOCK_SEARCH',
          N'BROKER_TO_FLUSH', N'BROKER_TASK_STOP', N'BROKER_RECEIVE_WAITFOR',
          N'SP_SERVER_DIAGNOSTICS_SLEEP', N'QDS_PERSIST_TASK_MAIN_LOOP_SLEEP',
          N'QDS_ASYNC_QUEUE', N'HADR_FILESTREAM_IOMGR_IOCOMPLETION',
          N'DISPATCHER_QUEUE_SEMAPHORE', N'SOS_WORK_DISPATCHER'
      )
)
SELECT
    CAST(100.0 * SUM(signal_wait_time_ms) / NULLIF(SUM(wait_time_ms), 0) AS DECIMAL(5,2))
        AS signal_wait_pct,   -- elevated => CPU / scheduler pressure
    CAST(100.0 * SUM(wait_time_ms - signal_wait_time_ms) / NULLIF(SUM(wait_time_ms), 0) AS DECIMAL(5,2))
        AS resource_wait_pct
FROM w;
```

---

## The Instance-Level Wait Query (with comprehensive benign filter)

`sys.dm_os_wait_stats` is full of background/idle waits that never represent a user-facing problem (system threads sleeping, the lazy writer, broker idle loops, Query Store's own background tasks, parallel-redo housekeeping). Filtering them out is essential — otherwise idle waits drown the signal. The list below is the consolidated community filter (Glenn Berry / Paul Randal lineage), expanded for modern versions.

```sql
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
        -- ── Sleeping / idle background waits ───────────────────────────────
        N'SLEEP_TASK',                       N'SLEEP_SYSTEMTASK',
        N'SLEEP_BPOOL_FLUSH',                N'SLEEP_DBSTARTUP',
        N'SLEEP_DCOMSTARTUP',                N'SLEEP_MASTERDBREADY',
        N'SLEEP_MASTERMDREADY',              N'SLEEP_MASTERUPGRADED',
        N'SLEEP_MSDBSTARTUP',                N'SLEEP_TEMPDBSTARTUP',
        N'LAZYWRITER_SLEEP',                 N'WAITFOR',
        N'WAITFOR_TASKSHUTDOWN',             N'WAIT_FOR_RESULTS',
        N'SERVER_IDLE_CHECK',                N'KSOURCE_WAKEUP',
        -- ── Checkpoint / log housekeeping ──────────────────────────────────
        N'CHECKPOINT_QUEUE',                 N'CHKPT',
        N'LOGMGR_QUEUE',                     N'DIRTY_PAGE_POLL',
        N'REDO_THREAD_PENDING_WORK',
        -- ── Service Broker idle loops ──────────────────────────────────────
        N'BROKER_EVENTHANDLER',              N'BROKER_RECEIVE_WAITFOR',
        N'BROKER_TASK_STOP',                 N'BROKER_TO_FLUSH',
        N'BROKER_TRANSMITTER',
        -- ── CLR / dispatcher / XE idle ─────────────────────────────────────
        N'CLR_AUTO_EVENT',                   N'CLR_MANUAL_EVENT',
        N'CLR_SEMAPHORE',                    N'DISPATCHER_QUEUE_SEMAPHORE',
        N'ONDEMAND_TASK_QUEUE',              N'SOS_WORK_DISPATCHER',
        N'XE_DISPATCHER_JOIN',               N'XE_DISPATCHER_WAIT',
        N'XE_TIMER_EVENT',                   N'XE_BUFFERMGR_ALLPROCESSED_EVENT',
        N'XE_LIVE_TARGET_TVF',
        -- ── Full-text idle ─────────────────────────────────────────────────
        N'FT_IFTS_SCHEDULER_IDLE_WAIT',      N'FT_IFTSHC_MUTEX',
        N'FSAGENT',
        -- ── Database mirroring / DBM idle ──────────────────────────────────
        N'DBMIRROR_DBM_EVENT',               N'DBMIRROR_EVENTS_QUEUE',
        N'DBMIRROR_WORKER_QUEUE',            N'DBMIRRORING_CMD',
        -- ── Always On / HADR idle & redo housekeeping ──────────────────────
        N'HADR_CLUSAPI_CALL',                N'HADR_FILESTREAM_IOMGR_IOCOMPLETION',
        N'HADR_LOGCAPTURE_WAIT',             N'HADR_NOTIFICATION_DEQUEUE',
        N'HADR_TIMER_TASK',                  N'HADR_WORK_QUEUE',
        N'PARALLEL_REDO_DRAIN_WORKER',       N'PARALLEL_REDO_LOG_CACHE',
        N'PARALLEL_REDO_TRAN_LIST',          N'PARALLEL_REDO_WORKER_SYNC',
        N'PARALLEL_REDO_WORKER_WAIT_WORK',
        -- ── Query Store background tasks ───────────────────────────────────
        N'QDS_PERSIST_TASK_MAIN_LOOP_SLEEP', N'QDS_ASYNC_QUEUE',
        N'QDS_CLEANUP_STALE_QUERIES_TASK_MAIN_LOOP_SLEEP',
        N'QDS_SHUTDOWN_QUEUE',
        -- ── In-Memory OLTP (XTP) housekeeping ──────────────────────────────
        N'WAIT_XTP_CKPT_CLOSE',              N'WAIT_XTP_HOST_WAIT',
        N'WAIT_XTP_OFFLINE_CKPT_NEW_LOG',    N'WAIT_XTP_RECOVERY',
        -- ── Diagnostics / trace / misc idle ────────────────────────────────
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
    -- Running cumulative percentage (Pareto view of the top waits)
    CAST(SUM(fw.wait_time_ms) OVER (ORDER BY fw.wait_time_ms DESC) * 100.0
        / NULLIF(t.total_wait_time_ms, 0) AS DECIMAL(5,2))    AS running_pct
FROM filtered_waits AS fw
CROSS JOIN total AS t
ORDER BY fw.wait_time_ms DESC;
```

**Reading it:** the top few rows that reach a `running_pct` of ~70–80% are your real bottleneck classes. A wait that appears with a high *count* but tiny *avg_wait_ms* is rarely a problem; a wait with a large *avg_wait_ms* (seconds) is worth investigating even if its share is modest.

> **Platform note.** On **Azure SQL Database** the equivalent is `sys.dm_db_wait_stats` (database-scoped) rather than `sys.dm_os_wait_stats`; the instance view is not exposed. On **Managed Instance** and **box**, `sys.dm_os_wait_stats` works as above. See `sqlserver-cloud`.

---

## Wait Category → Root Cause → Next Step

| Wait type(s) | Category | Likely root cause | Next diagnostic step |
|---|---|---|---|
| `SOS_SCHEDULER_YIELD` | CPU | CPU-bound queries; scans; spinlock contention at very high core counts | Top queries by CPU; runnable-task count per scheduler; check signal-wait % |
| `THREADPOOL` | CPU / workers | Worker thread exhaustion (often a blocking storm consuming all workers) | Resolve blocking; review `max worker threads`; check connection count |
| `CXPACKET` | Parallelism | Cost threshold too low; large parallel scans; skewed work distribution | Cost threshold (default 5 → 50); MAXDOP; find the parallel query/missing index |
| `CXCONSUMER` (2017+) | Parallelism | Benign producer/consumer coordination; usually *not* the problem alone | Correlate with the real wait (often I/O or CPU underneath) |
| `PAGEIOLATCH_SH/EX/UP` | Buffer I/O | Reading pages from disk: memory pressure and/or missing index causing scans | I/O latency DMV; PLE; missing-index DMVs; sort queries by reads |
| `WRITELOG` | Transaction log | Slow log volume; excessive tiny commits; too many VLFs | Log file latency (`dm_io_virtual_file_stats`); batch commits; log file sizing (`sqlserver-infrastructure`) |
| `LOGBUFFER` | Transaction log | Log buffer flush contention; very high commit rate | Same as WRITELOG; consider delayed durability (carefully) |
| `LCK_M_S/X/U/IX/RangeS-S/SCH-M` | Locking | Blocking; long/uncommitted transactions; lock escalation; schema locks vs DDL | Blocking chain → head blocker; transaction length; isolation level / RCSI |
| `RESOURCE_SEMAPHORE` | Memory grant | Queries requesting large grants (sorts/hashes) exhaust the grant pool | Pending grants DMV; fix over-estimating plans; reduce sort/hash spills |
| `RESOURCE_SEMAPHORE_QUERY_COMPILE` | Memory | Compilation memory pressure (many concurrent ad-hoc compiles) | Parameterize; reduce ad-hoc churn; optimize-for-ad-hoc |
| `CMEMTHREAD` | Memory | Thread-safe memory object contention (high plan-cache churn) | Reduce ad-hoc compiles; check `forced parameterization` need |
| `ASYNC_NETWORK_IO` | Network | **Client** not consuming the result set fast enough (RBAR, huge SELECT) | Application-side: fetch loops, ORM lazy loading, oversized result sets |
| `PAGELATCH_UP/EX` on `2:1:*` | tempdb | Allocation-page (PFS/GAM/SGAM) contention in tempdb | tempdb file count/sizing; metadata optimization (`sqlserver-infrastructure`) |
| `PAGELATCH_*` on a user db page | Buffer latch | Hot page (e.g. last page of an ever-increasing index) | Index design / hashing the key (`sqlserver-engineering`) |
| `HADR_SYNC_COMMIT` | AG | Sync-commit replica acknowledging slowly (network / remote log disk) | Replica health, log send/redo queue (`sqlserver-ha-clustering`) |
| `PREEMPTIVE_OS_*` | External | SQL thread called out to the OS (file ops, auth, extended procs) | Identify the external call; usually linked-server, xp_cmdshell, auth |
| `IO_COMPLETION` / `ASYNC_IO_COMPLETION` | Disk I/O | Non-buffer I/O: backups, sorts spilling, eager writes, file growth | I/O latency; autogrowth events; backup throughput (`sqlserver-operations`) |
| `BACKUPIO` / `BACKUPBUFFER` | Backup I/O | Backup target throughput | Backup tuning (`sqlserver-operations`) |

> **`THREADPOOL` lifeline — the DAC.** When workers are exhausted, *new normal connections cannot even log in* (the login itself needs a worker), so you may be locked out exactly when you need to diagnose. The **Dedicated Admin Connection (DAC)** runs on its own reserved scheduler/memory and is the way in. The **local DAC is always available** on the instance; connect with `sqlcmd -A` or, in SSMS, the `ADMIN:` server prefix (`ADMIN:ServerName`), then run the live blocking/scheduler DMVs to find the head blocker consuming workers. The **remote DAC is off by default** and must be enabled (`sp_configure 'remote admin connections', 1`); the harmonized plugin stance is to leave remote DAC disabled unless a documented operational need justifies it and it is firewalled to admins only — see `sqlserver-infrastructure`/`sqlserver-security`. Only one DAC session is allowed at a time, and don't run heavy queries over it.

---

## Per-Session Waits (2016+)

`sys.dm_exec_session_wait_stats` (SQL Server 2016+) gives waits **scoped to a single active session** — invaluable when one connection is slow but the instance looks fine. It is alive only while the session exists.

```sql
-- Waits accumulated by a specific live session (replace 123)
SELECT
    sws.session_id,
    sws.wait_type,
    sws.waiting_tasks_count,
    sws.wait_time_ms,
    sws.signal_wait_time_ms,
    sws.wait_time_ms - sws.signal_wait_time_ms          AS resource_wait_ms,
    sws.max_wait_time_ms
FROM sys.dm_exec_session_wait_stats AS sws
WHERE sws.session_id = 123
  AND sws.waiting_tasks_count > 0
ORDER BY sws.wait_time_ms DESC;
```

Pattern for isolating a workload: snapshot `sys.dm_exec_session_wait_stats` for the SPID into a temp table, run the workload, snapshot again, and diff — the cleanest way to attribute waits to one statement without clearing instance-wide stats.

---

## Per-Query Waits via Query Store (2017+)

When `WAIT_STATS_CAPTURE_MODE = ON` (default in 2017+ and in Azure SQL DB/MI), Query Store records waits **per query/plan** in `sys.query_store_wait_stats`, bucketed into ~24 human-readable categories (CPU, Buffer IO, Lock, Memory, Network IO, Parallelism, etc.) rather than raw wait types. This is the only place to answer "what did *this specific query* wait on, historically."

```sql
-- Top wait categories per query over the last 24 hours (run in the user DB)
SELECT TOP (25)
    q.query_id,
    qsws.wait_category_desc,
    SUM(qsws.total_query_wait_time_ms)                  AS total_wait_ms,
    SUM(qsws.total_query_wait_time_ms)
        / NULLIF(SUM(qsws.avg_query_wait_time_ms), 0)   AS approx_executions,
    LEFT(qt.query_sql_text, 120)                        AS query_text_snippet
FROM sys.query_store_wait_stats AS qsws
JOIN sys.query_store_plan         AS p   ON qsws.plan_id = p.plan_id
JOIN sys.query_store_query        AS q   ON p.query_id   = q.query_id
JOIN sys.query_store_query_text   AS qt  ON q.query_text_id = qt.query_text_id
JOIN sys.query_store_runtime_stats_interval AS rsi
     ON qsws.runtime_stats_interval_id = rsi.runtime_stats_interval_id
WHERE rsi.start_time >= DATEADD(HOUR, -24, SYSUTCDATETIME())
GROUP BY q.query_id, qsws.wait_category_desc, qt.query_sql_text
ORDER BY total_wait_ms DESC;
```

Full Query Store coverage is in `references/query-store.md`.

---

## Clearing Waits — Caveats (do not run blind)

`sys.dm_os_wait_stats` accumulates from service start. To compare *windows* of time you have two safe options and one destructive one:

1. **Snapshot and diff (preferred, non-destructive).** Capture the DMV into a table at T0 and T1 and subtract. No global side effects. This is how you baseline.
2. **`sys.dm_exec_session_wait_stats`** for a single session (above) — already window-scoped to the session's life.
3. **`DBCC SQLPERF(N'sys.dm_os_wait_stats', CLEAR);`** — *destructive*: it zeroes the instance-wide cumulative counters for everyone, erasing history other tools (monitoring software, your own baselines) rely on. **Mentioned for awareness only; the diagnostic scripts in this skill never clear stats.** If you must, do it deliberately and document it — never as a reflex.

The same snapshot/diff discipline applies to `sys.dm_io_virtual_file_stats` and `sys.dm_os_performance_counters`, which are likewise cumulative.

---

## A Worked Example

Symptom: "the app is slow in the afternoon."

1. **Waits** show `PAGEIOLATCH_SH` at 65% running_pct, low signal % → an I/O / memory read problem, not CPU.
2. **PLE** has collapsed from a 6,000 baseline to 90, and **buffer cache hit ratio** dropped → the buffer pool is churning; pages are being evicted and re-read.
3. **Top queries by logical reads** surface one report query doing 40M reads per run — a table scan.
4. **Plan** shows a clustered index scan with a huge cardinality misestimate; a **missing-index** suggestion exists.
5. **Hand off to `sqlserver-engineering`** to design a proper covering index (not the raw suggestion), and to `sqlserver-infrastructure` if `max server memory` is set too low for the data size.

Notice each step eliminated whole subsystems (CPU, locking, network) before touching a plan.

---

## Optional: community tools that accelerate this workflow

The bundled read-only scripts cover every step above with no dependencies. Where you are allowed to install community tooling, Brent Ozar's First Responder Kit (`sp_BlitzFirst`/`sp_BlitzWho` at "right now," `sp_BlitzCache` at top queries, `sp_BlitzLock` at deadlocks) and Erik Darling's PerformanceMonitor (continuous historical baselining) map directly onto this five-step method and can speed triage. They **complement, not replace** the waits-first discipline and the bundled scripts. See `references/community-diagnostic-tools.md` for the mapping, install pointers, and change-class/safety notes.
