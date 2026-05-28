# Extended Events & Performance Counters Reference

Two complementary observability surfaces:

- **Extended Events (XEvents)** — event-driven tracing. "Capture *every occurrence* of event X (with these fields) when condition Y holds." Replaces the deprecated SQL Trace / Profiler at a fraction of the overhead.
- **Performance counters** — sampled, mostly cumulative numeric metrics (the same family Windows Perfmon exposes), readable in T-SQL via `sys.dm_os_performance_counters`.

Use XEvents to answer "show me the actual deadlock / the statements over 5 s / the blocked-process reports." Use counters for trend lines and instance-wide rates (Batch Requests/sec, PLE, compilations/sec).

Applies to SQL Server 2016–2025. On Azure SQL Database, server-scoped XEvent sessions are replaced by **database-scoped** sessions (`CREATE EVENT SESSION ... ON DATABASE`) with a more limited event set, and counters are read from `sys.dm_db_resource_stats`/`sys.dm_os_performance_counters` as available — see `sqlserver-cloud`.

---

## Part 1 — Extended Events

### Architecture in one screen

| Concept | Meaning |
|---|---|
| **Event** | A point in engine execution that can fire (e.g. `sql_statement_completed`, `rpc_completed`, `xml_deadlock_report`, `blocked_process_report`, `wait_info`). |
| **Package** | Namespace grouping events/actions/targets (`sqlserver`, `package0`, `sqlos`). |
| **Predicate** | A filter evaluated *before* the event payload is fully collected — cheap, keeps overhead low (e.g. `duration > 5000000`). |
| **Action** | Extra data attached when an event fires (`sqlserver.sql_text`, `sqlserver.session_id`, `sqlserver.database_name`, `sqlserver.client_app_name`). Actions cost more than fields — add only what you need. |
| **Target** | Where events land: `ring_buffer` (memory, transient) or `event_file` (`.xel` on disk, durable). Also `histogram`, `event_counter`, `pair_matching`. |
| **Session** | The container you create, start, and stop. |

Why it replaced Profiler: predicates filter at the source, sessions run asynchronously to buffered targets, and the footprint is far smaller than server-side traces — safe to run lightweight sessions in production.

### The always-on `system_health` session

`system_health` runs by default on every instance and already records: deadlock graphs (`xml_deadlock_report`), errors severity ≥ 20, memory-related errors (701/802/8645…), long latch/lock waits, and `sp_server_diagnostics` output. **Check it before building anything** — the evidence you need is often already there. It uses both a ring_buffer and an event_file target (`system_health*.xel` in the LOG folder), so it retains a rolling history across the file set.

```sql
-- Confirm system_health is running
SELECT s.name, s.startup_state, rs.create_time
FROM sys.server_event_sessions AS s
LEFT JOIN sys.dm_xe_sessions AS rs ON s.name = rs.name
WHERE s.name = N'system_health';
```

### Session: long-running statements (> 5 s)

```sql
CREATE EVENT SESSION [LongRunningStatements] ON SERVER
ADD EVENT sqlserver.sql_statement_completed
(
    ACTION
    (
        sqlserver.sql_text,
        sqlserver.session_id,
        sqlserver.database_name,
        sqlserver.client_app_name,
        sqlserver.client_hostname,
        sqlserver.username
    )
    WHERE duration > 5000000          -- microseconds => 5 seconds
)
ADD TARGET package0.event_file
(
    SET filename = N'LongRunningStatements.xel',
        max_file_size = 100,          -- MB per file
        max_rollover_files = 5
)
WITH
(
    MAX_MEMORY = 8 MB,
    EVENT_RETENTION_MODE = ALLOW_SINGLE_EVENT_LOSS,   -- never block the engine to keep a trace
    MAX_DISPATCH_LATENCY = 30 SECONDS,
    STARTUP_STATE = ON
);
GO
ALTER EVENT SESSION [LongRunningStatements] ON SERVER STATE = START;
```

### Session: deadlocks (durable history)

`system_health` captures deadlocks but its ring buffer rolls over; a dedicated `event_file` session keeps a clean, long-lived record.

```sql
CREATE EVENT SESSION [DeadlockCapture] ON SERVER
ADD EVENT sqlserver.xml_deadlock_report
ADD TARGET package0.event_file
(
    SET filename = N'DeadlockCapture.xel',
        max_file_size = 50,
        max_rollover_files = 10
)
WITH (STARTUP_STATE = ON, EVENT_RETENTION_MODE = ALLOW_SINGLE_EVENT_LOSS);
GO
ALTER EVENT SESSION [DeadlockCapture] ON SERVER STATE = START;
```

### Session: blocked-process report (requires sp_configure)

The `blocked_process_report` event only fires if the **blocked process threshold** is enabled (it is off by default). The threshold is in *seconds*; SQL Server raises the report when a process is blocked that long.

```sql
-- [CONFIG CHANGE] One-time prerequisite (value in SECONDS). 20s is a reasonable production starting point.
-- This persists instance-wide and adds a small background monitor overhead; setting it to 0 disables it.
-- 'show advanced options' is itself an advanced-options toggle — reset it to 0 afterward to leave config clean.
EXEC sp_configure 'show advanced options', 1;  RECONFIGURE;
EXEC sp_configure 'blocked process threshold', 20;  RECONFIGURE;
EXEC sp_configure 'show advanced options', 0;  RECONFIGURE;   -- reset advanced-options visibility
GO

CREATE EVENT SESSION [BlockedProcessReport] ON SERVER
ADD EVENT sqlserver.blocked_process_report
ADD TARGET package0.event_file
(
    SET filename = N'BlockedProcessReport.xel',
        max_file_size = 50,
        max_rollover_files = 5
)
WITH (STARTUP_STATE = ON, EVENT_RETENTION_MODE = ALLOW_SINGLE_EVENT_LOSS);
GO
ALTER EVENT SESSION [BlockedProcessReport] ON SERVER STATE = START;
```

### ring_buffer vs event_file — choosing a target

| | `ring_buffer` | `event_file` |
|---|---|---|
| Storage | In memory (fixed size, oldest evicted) | On disk (`.xel`, rollover files) |
| Survives restart | No | Yes |
| Best for | Quick ad-hoc capture you'll read immediately | History, post-mortem, anything you'll query later |
| Reading | XML out of `sys.dm_xe_session_targets` | `sys.fn_xe_file_target_read_file()` |

### Reading targets

Reading a **ring_buffer** target (e.g. for an ad-hoc `wait_info` session):

```sql
SELECT CAST(t.target_data AS XML) AS target_xml
FROM sys.dm_xe_sessions AS s
JOIN sys.dm_xe_session_targets AS t ON s.address = t.event_session_address
WHERE s.name = N'YourSession'
  AND t.target_name = N'ring_buffer';
-- then .nodes()/.value() into the RingBufferTarget/event nodes
```

Reading an **event_file** target — the `.xel` files (note `*` to span rollovers):

```sql
SELECT
    object_name                                         AS event_name,
    CONVERT(XML, event_data)                            AS event_xml,
    CONVERT(XML, event_data).value(
        '(event/@timestamp)[1]','DATETIME2')            AS event_time_utc
FROM sys.fn_xe_file_target_read_file(N'LongRunningStatements*.xel', NULL, NULL, NULL);
```

Extract the deadlock graph from the **system_health** ring buffer (this is exactly what script `06` does):

```sql
SELECT
    dl.value('(event/@timestamp)[1]','DATETIME2')       AS deadlock_time_utc,
    dl.query('(event/data[@name="xml_report"]/value/deadlock)[1]') AS deadlock_graph
FROM
(
    SELECT CAST(t.target_data AS XML) AS target_xml
    FROM sys.dm_xe_sessions AS s
    JOIN sys.dm_xe_session_targets AS t ON s.address = t.event_session_address
    WHERE s.name = N'system_health'
      AND t.target_name = N'ring_buffer'
) AS d
CROSS APPLY target_xml.nodes('RingBufferTarget/event[@name="xml_deadlock_report"]') AS x(dl);
```

### Housekeeping

```sql
-- List sessions and whether they're running
SELECT s.name, s.startup_state, (CASE WHEN r.name IS NULL THEN 'STOPPED' ELSE 'RUNNING' END) AS state
FROM sys.server_event_sessions AS s
LEFT JOIN sys.dm_xe_sessions AS r ON s.name = r.name
ORDER BY s.name;

-- Stop / drop a session when done (don't leave ad-hoc traces running)
-- ALTER EVENT SESSION [LongRunningStatements] ON SERVER STATE = STOP;
-- DROP EVENT SESSION [LongRunningStatements] ON SERVER;
```

Keep sessions lean: minimal events, tight predicates, only the actions you need, `ALLOW_SINGLE_EVENT_LOSS` so tracing never blocks the workload, and a bounded file set. Drop ad-hoc sessions after the investigation.

### Azure SQL Database: database-scoped sessions to Blob Storage

On **Azure SQL Database** there is no instance, so every session is **database-scoped**: use `CREATE EVENT SESSION ... ON DATABASE` (not `ON SERVER`), and the event set is narrower than box/MI. The `event_file` target **cannot write to a local path** — there is no local disk you can address — it must write the `.xel` to **Azure Blob Storage**. That requires, one-time:

1. A storage account + a blob **container**.
2. Authorization for the logical server to write to it — either the server's **managed identity** granted *Storage Blob Data Contributor* on the container, or a **SAS token** with `rwdl` (read/write/delete/list) permission.
3. A **database-scoped credential** whose name is the **container URL** (no trailing slash), pointing at that identity/SAS.

```sql
-- Azure SQL DB only. SECRET must come from a secret manager — never commit; rotate any value ever copied.
-- [SECURITY CHANGE] creates a DB-scoped credential.
-- CREATE DATABASE SCOPED CREDENTIAL [https://<account>.blob.core.windows.net/<container>]
--     WITH IDENTITY = 'SHARED ACCESS SIGNATURE',
--          SECRET   = N'<generate-32+char-random-secret>';   -- SAS token (no leading '?')

CREATE EVENT SESSION [LongRunningStatements] ON DATABASE   -- ON DATABASE, not ON SERVER
ADD EVENT sqlserver.sql_statement_completed (WHERE duration > 5000000)
ADD TARGET package0.event_file
(
    SET filename = N'https://<account>.blob.core.windows.net/<container>/LongRunningStatements.xel'
)
WITH (MAX_MEMORY = 8 MB, EVENT_RETENTION_MODE = ALLOW_SINGLE_EVENT_LOSS, STARTUP_STATE = ON);
GO
ALTER EVENT SESSION [LongRunningStatements] ON DATABASE STATE = START;
```

Read it back with the same `sys.fn_xe_file_target_read_file()` passing the blob URL. **Managed Instance** behaves like box (server-scoped sessions, local/UNC file targets). Verify the current event surface and credential steps on Microsoft Learn for your tier. Details in `sqlserver-cloud`.

---

## Part 2 — Performance Counters

`sys.dm_os_performance_counters` exposes SQL Server's Perfmon counters in T-SQL. The catch is that counters come in several **types** (`cntr_type`) and you must interpret each correctly — reading the raw `cntr_value` is wrong for most of them.

### Counter types you must handle

| `cntr_type` | Name | How to read |
|---|---|---|
| `65792` | Value/base (raw) | Use `cntr_value` directly (e.g. Page life expectancy, Memory Grants Pending). |
| `272696576` | Per-second (cumulative) | Take **two snapshots** and divide the delta by the elapsed seconds (e.g. Batch Requests/sec). The raw value alone is a running total, not a rate. |
| `537003264` | Ratio (numerator) | Pair with its matching `1073939712` **base** counter: `100.0 * value / base` (e.g. Buffer cache hit ratio). |
| `1073939712` | Ratio base | The denominator partner for the ratio above; never reported on its own. |
| `1073874176` | Bulk count (avg op) | Numerator paired with a base, for per-operation averages. |

**The two patterns that trip people up:**

1. **Ratio/base pattern.** "Buffer cache hit ratio" of, say, `1500` is meaningless until divided by "Buffer cache hit ratio base" — the result is the real percentage. Always join the counter to its base by `object_name` + matching counter name.
2. **Per-second delta pattern.** "Batch Requests/sec" is stored as a *cumulative count*. To get an actual rate, snapshot it, wait a known interval, snapshot again, and divide the difference by the elapsed seconds.

### Key counters and how to read them

| Counter (object → counter) | Type | Healthy direction | What it tells you |
|---|---|---|---|
| Buffer Manager → **Buffer cache hit ratio** (+ base) | ratio | > ~99% OLTP | % of page requests served from memory |
| Buffer Manager → **Page life expectancy** | raw | higher; **baseline-relative** | seconds a page stays in the pool; a sudden drop = memory churn |
| Buffer Manager → **Page reads/sec**, **Page writes/sec** | per-sec | lower | physical I/O rate against the buffer pool |
| SQL Statistics → **Batch Requests/sec** | per-sec | workload-dependent | overall throughput; the headline activity metric |
| SQL Statistics → **SQL Compilations/sec** | per-sec | low vs batches | high ratio to batches = plan-cache churn / ad-hoc |
| SQL Statistics → **SQL Re-Compilations/sec** | per-sec | low | recompiles (stats changes, `RECOMPILE`, schema changes) |
| General Statistics → **User Connections** | raw | — | connection count (sudden spikes correlate with `THREADPOOL`) |
| General Statistics → **Processes blocked** | raw | 0 | currently blocked processes (instant blocking gauge) |
| Locks → **Lock Waits/sec**, **Lock Wait Time (ms)** | per-sec | low | contention rate; corroborates `LCK_*` waits |
| Locks → **Number of Deadlocks/sec** | per-sec | 0 | deadlock rate |
| Memory Manager → **Memory Grants Pending** | raw | 0 | queries waiting for a workspace grant (`RESOURCE_SEMAPHORE`) |
| Memory Manager → **Memory Grants Outstanding** | raw | — | grants currently held |
| Access Methods → **Page Splits/sec** | per-sec | low | mid-page splits (fragmentation, bad fill factor / clustered key) |
| Access Methods → **Forwarded Records/sec** | per-sec | low | heap forwarding (consider a clustered index) |
| Databases → **Log Flush Wait Time**, **Log Flushes/sec** | mixed | low | commit-path log pressure; corroborates `WRITELOG` |

> `object_name` is prefixed with the instance: default instance counters start `SQLServer:` (e.g. `SQLServer:Buffer Manager`); a named instance uses `MSSQL$INSTANCE:`. Match with `LIKE '%Buffer Manager%'` to be instance-name-agnostic.

### Raw counters (read `cntr_value` directly)

```sql
SELECT
    RTRIM(counter_name)                                 AS counter_name,
    RTRIM(instance_name)                                AS instance_name,
    cntr_value
FROM sys.dm_os_performance_counters
WHERE
    (object_name LIKE N'%Buffer Manager%' AND counter_name = N'Page life expectancy')
 OR (object_name LIKE N'%Memory Manager%' AND counter_name IN (N'Memory Grants Pending', N'Memory Grants Outstanding'))
 OR (object_name LIKE N'%General Statistics%' AND counter_name = N'Processes blocked')
ORDER BY counter_name, instance_name;
```

### Ratio/base pattern (Buffer cache hit ratio)

```sql
SELECT
    CAST(100.0 * ratio.cntr_value / NULLIF(base.cntr_value, 0) AS DECIMAL(5,2))
        AS buffer_cache_hit_ratio_pct
FROM sys.dm_os_performance_counters AS ratio
JOIN sys.dm_os_performance_counters AS base
    ON  ratio.object_name = base.object_name
WHERE ratio.counter_name = N'Buffer cache hit ratio'
  AND base.counter_name  = N'Buffer cache hit ratio base'
  AND ratio.object_name LIKE N'%Buffer Manager%';
```

### Per-second delta pattern (true rates without Perfmon)

Because per-second counters are cumulative, compute a real rate by sampling twice with a known gap. (`WAITFOR DELAY` is used here purely as the sampling interval — this is read-only.)

```sql
DECLARE @t0 TABLE (counter_name SYSNAME, v BIGINT);
INSERT INTO @t0
SELECT RTRIM(counter_name), cntr_value
FROM sys.dm_os_performance_counters
WHERE counter_name IN (N'Batch Requests/sec', N'SQL Compilations/sec',
                       N'SQL Re-Compilations/sec', N'Page reads/sec', N'Page writes/sec')
  AND instance_name = N'';

DECLARE @interval_s INT = 5;
WAITFOR DELAY '00:00:05';

;WITH t1 AS
(
    SELECT RTRIM(counter_name) AS counter_name, cntr_value AS v
    FROM sys.dm_os_performance_counters
    WHERE counter_name IN (N'Batch Requests/sec', N'SQL Compilations/sec',
                           N'SQL Re-Compilations/sec', N'Page reads/sec', N'Page writes/sec')
      AND instance_name = N''
)
SELECT
    t1.counter_name,
    CAST((t1.v - t0.v) * 1.0 / @interval_s AS DECIMAL(18,2)) AS per_second_rate
FROM t1
JOIN @t0 AS t0 ON t1.counter_name = t0.counter_name
ORDER BY t1.counter_name;
```

A common derived health signal: **Compilations/sec ÷ Batch Requests/sec**. If a large fraction of batches compile, you have plan-cache churn — usually unparameterized ad-hoc SQL. Consider `optimize for ad hoc workloads` or forced parameterization (config work → `sqlserver-infrastructure`; query-side parameterization → `sqlserver-engineering`).

> **Cloud note.** On **Azure SQL Database**, prefer `sys.dm_db_resource_stats` (per-DB CPU/IO/memory %, 15-second granularity, ~1 hour history) and `sys.resource_stats` (master DB, 5-minute, 14 days) for resource trends; many instance-level counters are absent. **Managed Instance** exposes `sys.dm_os_performance_counters` like the box product. Details in `sqlserver-cloud`.
