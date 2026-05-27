# SQL Server Instance Configuration Reference

Server-level configuration (`sp_configure`) and database-scoped configuration that shape how the engine uses the platform. This is the *what to set and why*; the diagnostics that report current values are `scripts/01-instance-config-audit.sql` and `scripts/07-database-scoped-config.sql`.

**Scope:** box product 2016–2025 on Windows/Linux/containers. On **Azure SQL Database** most of `sp_configure` does not exist (use database-scoped config and the portal); on **Managed Instance** a subset applies. Confirm platform first (`SELECT SERVERPROPERTY('EngineEdition');` — 5 = Azure SQL DB, 8 = MI). PaaS depth lives in **sqlserver-cloud**.

---

## How `sp_configure` and `RECONFIGURE` Work

`sp_configure` has two value columns that matter:

- **`value`** — the configured value you just set (the *requested* value).
- **`value_in_use`** — the value the engine is actually running with.

`RECONFIGURE` promotes `value` → `value_in_use` for settings that take effect without a restart. Settings flagged as **self-configuring / restart-required** (e.g., `max worker threads`, `priority boost`, `lightweight pooling`, `affinity mask`) stay pending — `value <> value_in_use` — until the service restarts. Script 01 surfaces exactly this gap so you can tell "set but not active" from "set and live."

```sql
-- Advanced settings are hidden until you turn them on
EXEC sp_configure 'show advanced options', 1;
RECONFIGURE;

-- Change a setting, then activate it
EXEC sp_configure 'cost threshold for parallelism', 50;
RECONFIGURE;   -- use RECONFIGURE WITH OVERRIDE only when you must bypass validity checks

-- Inspect the result
SELECT name, value, value_in_use, is_dynamic, is_advanced
FROM   sys.configurations
WHERE  name IN ('cost threshold for parallelism','max degree of parallelism');
```

`RECONFIGURE WITH OVERRIDE` skips the value-range/validity check — only use it deliberately (e.g., setting `min server memory` above the current `max server memory` temporarily during a staged change).

---

## Memory: `max server memory` and `min server memory`

### The sizing formula

Do **not** use "half the RAM." Reserve memory for the OS and the non-buffer-pool consumers, then give the rest to SQL:

```
max server memory = Total RAM
                    − OS reservation (≈ 4 GB baseline; more on very large boxes)
                    − 1 GB for every 4 GB of RAM above 16 GB
                    − whatever other services on the box need (SSIS/SSRS/SSAS, agents, AV, app)
```

| Total RAM | OS + headroom | Recommended `max server memory` |
|---|---|---|
| 16 GB | ~4 GB | ~12 GB (12288 MB) |
| 32 GB | ~8 GB | ~24 GB (24576 MB) |
| 64 GB | ~16 GB | ~48 GB (49152 MB) |
| 128 GB | ~24–28 GB | ~100–104 GB (~102400 MB) |
| 256 GB | ~32–40 GB | ~216–224 GB (~221184 MB) |

```sql
-- 64 GB dedicated box: 64 − 4 − ((64−16)/4) = 48 GB
EXEC sp_configure 'max server memory (MB)', 49152;
RECONFIGURE;
```

**Version note:** on **2019+**, `max server memory` accounts for essentially *all* SQL memory (the historical "buffer pool only" limitation is gone), so the cap is now an accurate ceiling. On 2016/2017 the cap still mostly governed the buffer pool, so leave a touch more headroom.

### `min server memory`

- Leave at **0** on a dedicated SQL box — SQL grows its working set on demand and the OS reclaims it only under genuine pressure.
- Set a **floor** only where SQL shares the box with another memory-hungry service and you have observed SQL being trimmed too aggressively. A common floor is 25–50% of `max server memory`.
- `min server memory` is *not* pre-allocated at startup; it is the level below which SQL will not voluntarily give memory back.

LPIM, NUMA balancing, and the memory regions themselves are covered in `memory-and-cpu.md`.

---

## Parallelism: cost threshold and MAXDOP

### `cost threshold for parallelism`

The optimizer considers a parallel plan only when the serial plan's estimated cost exceeds this threshold. The default of **5** dates to single-CPU hardware and is far too low — trivial queries get parallel plans, paying coordination overhead (`CXPACKET`/`CXCONSUMER`) for no benefit.

```sql
EXEC sp_configure 'cost threshold for parallelism', 50;  -- start at 50, then tune
RECONFIGURE;
```

Tune by looking at where your actual query costs cluster (the distribution of per-query CPU is a useful proxy; deeper plan-cost analysis is **sqlserver-engineering**/**sqlserver-monitoring**). Push higher (75–100) on pure OLTP, lower it toward 25–40 on DW/reporting where parallelism pays off.

### `max degree of parallelism (MAXDOP)`

Caps the number of schedulers a single parallel query operator can use. **0** = unlimited (up to 64), which is wrong on most multi-core/NUMA hardware.

Starting point (Microsoft's guidance and field practice):

| Hardware | Recommended MAXDOP |
|---|---|
| ≤ 8 logical cores, single NUMA node | ≤ number of cores (often = cores) |
| > 8 cores, single NUMA node | 8 |
| Multiple NUMA nodes | number of **physical** cores in **one** NUMA node, capped at 8 |
| Pure OLTP, latency-sensitive | 1–4 (lower to suppress parallel waits) |
| Data warehouse / reporting | 4–8 (let bigger queries parallelize) |

```sql
EXEC sp_configure 'max degree of parallelism', 8;
RECONFIGURE;
```

Count **physical** cores, not logical — do not include hyperthreads in the per-node figure. MAXDOP can also be overridden per database (database-scoped, below), per query (`OPTION (MAXDOP n)`), and via Resource Governor. NUMA detail and the scheduler view are in `memory-and-cpu.md`.

---

## Plan-cache and workload settings

### `optimize for ad hoc workloads`

```sql
EXEC sp_configure 'optimize for ad hoc workloads', 1;
RECONFIGURE;
```

On first execution of an ad-hoc batch, SQL caches a small **plan stub** instead of the full compiled plan; only on the *second* execution is the full plan cached. This stops a flood of single-use plans from bloating the plan cache. **Turn it on** on virtually every instance — it is safe and purely beneficial for mixed/ad-hoc workloads.

### `max worker threads`

```sql
-- Leave at 0 (auto). The auto formula scales with CPU count and bitness.
-- Only change with strong evidence of THREADPOOL waits, and understand the memory cost.
-- EXEC sp_configure 'max worker threads', 0;  RECONFIGURE;  (restart required)
```

`0` = auto: SQL computes a sensible value from the logical CPU count (e.g., 512 at 4 CPUs up to several thousand on many-core x64). Each thread costs ~512 KB of stack. Raising it is a band-aid for `THREADPOOL` waits whose real cause is usually long blocking — diagnose first (**sqlserver-monitoring**). Restart required to change.

### `backup compression default`

```sql
EXEC sp_configure 'backup compression default', 1;
RECONFIGURE;
```

Makes every backup compressed unless overridden. Smaller and usually *faster* (less I/O). Available in Standard+ from 2016 SP1. Backup strategy lives in **sqlserver-operations**; this just sets the instance default.

---

## Availability and break-glass settings

### `remote admin connections` (the DAC)

```sql
EXEC sp_configure 'remote admin connections', 1;  -- allow the DAC from remote hosts
RECONFIGURE;
```

The **Dedicated Admin Connection** reserves a scheduler and memory so you can connect to a hung instance (`sqlcmd -A`). By default the DAC is local-only; setting this to 1 allows it from another machine — essential when the box is so wedged you cannot RDP in. Connection/port plumbing is in `platform-and-network.md`.

### `blocked process threshold (s)`

```sql
EXEC sp_configure 'blocked process threshold', 15;  -- seconds; 0 = off
RECONFIGURE;
```

When a process is blocked longer than this, SQL generates a **blocked-process report** event (capture it with an Extended Events session). Set to 5–20 seconds. The capture and analysis are **sqlserver-monitoring**; this is just the trigger. Do not set it to 1–4 (noise and overhead).

---

## Settings to leave at default (or explicitly OFF)

| Setting | Leave at | Why |
|---|---|---|
| `priority boost` | **0 (off)** | Raises SQL's Windows priority above OS threads — starves the OS, can hang the box, and is unsupported with clustering. Never enable. (Restart required even to set.) |
| `lightweight pooling` | **0 (off)** | Fiber mode; breaks CLR, linked servers, Extended Stored Procs, and more. Almost never appropriate. |
| `default fill factor` | **0 (=100)** | A global non-100 fill factor wastes space across *every* index. Set fill factor per-index where needed, not server-wide. |
| `affinity mask` / `affinity I/O mask` | default (auto) | Only pin CPUs when intentionally partitioning cores between instances. See `memory-and-cpu.md`. |
| `fill factor` server default | 0 | Same as above. |
| `network packet size` | 4096 | Default is right for almost everyone; only large bulk/ETL flows benefit from raising it. |
| `cross db ownership chaining` | 0 (off) | Security risk; enable per-database only if truly required (cross-ref **sqlserver-security**). |
| `clr enabled` | per requirement | Off by default; enable only if you run CLR assemblies, and prefer `clr strict security` on (2017+). |

---

## Database-Scoped Configurations (2016+)

`ALTER DATABASE SCOPED CONFIGURATION` sets behavior **per database** (and independently on **secondary replicas** via the `FOR SECONDARY` clause), overriding the instance value where applicable. This is the modern way to apply many former trace flags and per-DB optimizer settings without an instance-wide change. Reported by `scripts/07-database-scoped-config.sql`.

| Option | Default | Effect / when to change |
|---|---|---|
| `MAXDOP` | 0 (inherit instance) | Per-DB parallelism cap; overrides the instance MAXDOP for this database |
| `LEGACY_CARDINALITY_ESTIMATION` | OFF | Force the pre-2014 CE for a DB that regressed under the new CE (engineering decision — see **sqlserver-engineering**) |
| `PARAMETER_SNIFFING` | ON | Set OFF to disable sniffing DB-wide (equivalent to TF 4136 / `OPTIMIZE FOR UNKNOWN`) when a DB suffers chronic sniffing pain |
| `QUERY_OPTIMIZER_HOTFIXES` | OFF | ON = enable optimizer hotfixes for this DB (the per-DB equivalent of TF 4199) |
| `OPTIMIZE_FOR_AD_HOC_WORKLOADS` | OFF | (2019+) per-DB plan-stub caching, mirroring the instance setting |
| `IDENTITY_CACHE` | ON | OFF to avoid identity gaps after unexpected restart/failover |
| `ELEVATE_ONLINE` / `ELEVATE_RESUMABLE` | OFF | (2019+) auto-elevate index ops to ONLINE/RESUMABLE |

```sql
-- Per-database MAXDOP override
ALTER DATABASE SCOPED CONFIGURATION SET MAXDOP = 4;

-- Different MAXDOP on the readable secondary (e.g., reporting offload)
ALTER DATABASE SCOPED CONFIGURATION FOR SECONDARY SET MAXDOP = 8;

-- Enable optimizer hotfixes for just this database (per-DB TF 4199)
ALTER DATABASE SCOPED CONFIGURATION SET QUERY_OPTIMIZER_HOTFIXES = ON;

-- Pin the legacy cardinality estimator for a regressed database
ALTER DATABASE SCOPED CONFIGURATION SET LEGACY_CARDINALITY_ESTIMATION = ON;

-- Inspect current values for the current database
SELECT configuration_id, name, value, value_for_secondary, is_value_default
FROM   sys.database_scoped_configurations
ORDER BY name;
```

Note `compatibility_level` (set with `ALTER DATABASE ... SET COMPATIBILITY_LEVEL = 160`) is the master switch for optimizer behavior and is *not* a scoped configuration — it lives in `sys.databases`. Compatibility-level strategy is **sqlserver-engineering**.

---

## Recommended-Baseline Checklist

Apply after confirming version/edition/platform and right-sizing inputs. All non-restart unless noted.

```sql
EXEC sp_configure 'show advanced options', 1; RECONFIGURE;

-- Memory: replace 49152 with your computed value (formula above)
EXEC sp_configure 'max server memory (MB)', 49152;        RECONFIGURE;
EXEC sp_configure 'min server memory (MB)', 0;            RECONFIGURE;

-- Parallelism: set MAXDOP to physical cores per NUMA node (cap 8)
EXEC sp_configure 'cost threshold for parallelism', 50;   RECONFIGURE;
EXEC sp_configure 'max degree of parallelism', 8;         RECONFIGURE;

-- Plan cache & backups
EXEC sp_configure 'optimize for ad hoc workloads', 1;     RECONFIGURE;
EXEC sp_configure 'backup compression default', 1;        RECONFIGURE;

-- Break-glass & blocking visibility
EXEC sp_configure 'remote admin connections', 1;          RECONFIGURE;
EXEC sp_configure 'blocked process threshold', 15;        RECONFIGURE;

-- Confirm these are OFF
EXEC sp_configure 'priority boost', 0;                    RECONFIGURE;  -- restart to change if it was on
EXEC sp_configure 'lightweight pooling', 0;               RECONFIGURE;  -- restart to change if it was on
```

**Then, beyond `sp_configure`:**

1. Grant **Perform Volume Maintenance Tasks** (IFI) to the SQL service account — see `storage-and-tempdb.md`.
2. Decide on **Lock Pages in Memory** for physical/VM hosts — see `memory-and-cpu.md`.
3. Configure **tempdb** files (count/size/growth/metadata optimization) — see `storage-and-tempdb.md`.
4. Set durable **trace flags** as `-T` startup parameters where still needed — see `platform-and-network.md`.
5. Apply **per-database** scoped configs (MAXDOP, hotfixes, CE) where a database needs to differ.
6. Verify everything with `scripts/01-instance-config-audit.sql` (watch for `value <> value_in_use` = pending restart).
