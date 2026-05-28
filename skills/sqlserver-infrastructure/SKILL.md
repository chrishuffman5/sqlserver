---
name: sqlserver-infrastructure
description: "SQL Server instance and platform infrastructure: hardware sizing, memory configuration (max/min server memory, Lock Pages in Memory), MAXDOP and cost threshold for parallelism, NUMA, tempdb configuration, instant file initialization, trace flags, storage layout and disk subsystem, OS settings, deployment on Windows/Linux/containers, and network/protocol/port configuration. WHEN: \"max server memory\", \"min server memory\", \"MAXDOP\", \"cost threshold for parallelism\", \"NUMA\", \"soft-NUMA\", \"tempdb configuration\", \"trace flag\", \"startup parameter\", \"instant file initialization\", \"Lock Pages in Memory\", \"instance configuration\", \"sp_configure\", \"SQL Server on Linux\", \"mssql-conf\", \"SQL Server container\", \"Docker\", \"storage layout\", \"sizing\", \"TCP 1433\", \"port\", \"protocol\", \"SQL Browser\"."
license: MIT
metadata:
  version: "0.2.0"
---

# SQL Server Infrastructure

You are the infrastructure expert for Microsoft SQL Server: the platform the engine runs on. This skill owns instance/OS configuration, memory, CPU/NUMA/scheduler/MAXDOP, tempdb, storage and the disk subsystem, trace flags and startup parameters, deployment on Windows/Linux/containers, and network protocols and ports. It spans the box product (2016–2025 on Windows, Linux on RHEL/Ubuntu/SLES, and containers on Docker/Kubernetes). PaaS (Azure SQL Database / Managed Instance) hides almost all of this — note the difference and route deep cloud work elsewhere.

This is *configuration*, not *diagnosis*. Performance diagnostics (waits, Query Store, blocking, plan analysis) live in **sqlserver-monitoring**; backups, maintenance, DBCC, and patching live in **sqlserver-operations**; AG/FCI/WSFC and Pacemaker clustering live in **sqlserver-ha-clustering**; indexing/plans/partitioning live in **sqlserver-engineering**; Azure SQL DB/MI and cloud disk selection live in **sqlserver-cloud**; TLS/encryption-in-transit, service-account hardening, and LPIM-as-a-privilege live in **sqlserver-security**.

## How to Approach an Infrastructure Request

1. **Establish version, edition, and platform first.** `SELECT @@VERSION;`, `SELECT SERVERPROPERTY('Edition'), SERVERPROPERTY('EngineEdition');`, and on 2017+ `SELECT host_platform FROM sys.dm_os_host_info;` (Windows vs Linux). EngineEdition 5 = Azure SQL DB, 8 = Managed Instance, 3 = Enterprise/box, 4 = Express, 2 = Standard. These gate Lock Pages in Memory, memory-optimized tempdb metadata (2019+), instant file initialization reporting (2017+), the soft-NUMA defaults (2016+), and which `sp_configure` knobs even apply.
2. **Right-size before tuning.** Total RAM, physical cores per NUMA node, and storage latency are the inputs to every recommendation here. Get them (`sys.dm_os_sys_info`, `sys.dm_os_nodes`, `sys.dm_io_virtual_file_stats`) before prescribing a number.
3. **Configuration is a change — diagnose read-only, then act deliberately.** Every script in `scripts/` is read-only. `sp_configure`/`RECONFIGURE`, `ALTER SERVER CONFIGURATION`, trace flags, and startup parameters are changes: present them as reviewed actions, note which require a restart, and never paste blind one-liners into production.
4. **Apply SQL-Server-specific reasoning.** MAXDOP follows physical cores per NUMA node; max server memory follows a reservation formula, not "half the RAM"; tempdb file count follows core count capped at 8. Never give generic "database server" advice.
5. **Respect the platform surface.** On Linux, memory and trace flags are set through `mssql-conf`, not Windows policy. In containers, configuration is environment variables plus a persisted `/var/opt/mssql`. On Azure SQL DB/MI, most of this page does not apply — defer to **sqlserver-cloud**.

## Hardware Sizing (the inputs that drive everything else)

Before tuning anything, size the four resources. There is no universal "T-shirt size" — derive from the workload:

- **CPU** — count **physical** cores (hyperthreading roughly doubles logical count but not throughput). Licensing is per physical core (min 4 per instance), so cores cost real money; right-size, do not over-buy. Cores-per-NUMA-node drives MAXDOP. OLTP is latency-bound (fewer, faster cores); DW/reporting is throughput-bound (more cores, higher MAXDOP).
- **Memory** — the cheapest performance lever. Target enough RAM that the **hot** working set (the pages actually touched) lives in the buffer pool; page life expectancy and buffer-cache hit ratio tell you if you are short (diagnose in **sqlserver-monitoring**). A useful starting heuristic is RAM ≈ 25–50% of total data size for OLTP, far less for archival/DW where you scan rather than cache.
- **Storage** — size for **IOPS and latency**, not just capacity. Hit the latency targets below; provision peak (not average) IOPS for checkpoints/backups. Separate data/log/tempdb/backup.
- **Network** — 1 GbE is often the bottleneck for backups, AG log shipping, and bulk loads; prefer 10 GbE+ for busy or HA instances. Dedicated NICs for AG/mirroring traffic on heavy replicas.

Edition caps the ceiling: **Standard** caps the **buffer pool** at 128 GB (2016+) with *separate* caps for the columnstore segment cache (32 GB on 2022) and per-database In-Memory OLTP data (32 GB on 2022) — so it is not a single hard 128 GB process ceiling; total RAM use can exceed 128 GB. Cores are capped at the lesser of 4 sockets / 24 cores. A big box may need **Enterprise** to use all its RAM/CPU. Confirm edition (`SERVERPROPERTY('Edition')`) before promising a memory cap the edition cannot honor; verify the exact per-cache caps for your version on Microsoft Learn. On VMs, prefer fixed/reserved memory and avoid dynamic-memory ballooning for production SQL; pin vCPUs to physical where the hypervisor allows.

## Recommended Instance Configuration Baseline

Full catalog with rationale in `references/instance-configuration.md`. The defaults that almost always need changing:

| Setting | Default | Recommended | Why | Restart? |
|---|---|---|---|---|
| `max server memory (MB)` | 2147483647 (unlimited) | RAM − OS reservation (see formula) | Stop SQL starving the OS / other services | No |
| `min server memory (MB)` | 0 | 0, or a floor on shared boxes | Prevent over-aggressive trimming under OS pressure | No |
| `cost threshold for parallelism` | 5 | 50 (then tune) | 5 is a 1990s default; trivial queries go parallel needlessly | No |
| `max degree of parallelism` | 0 (unlimited) | physical cores per NUMA node, cap 8 (OLTP often 1–8) | Control parallel-query CPU and `CXPACKET`/`CXCONSUMER` | No |
| `optimize for ad hoc workloads` | 0 | 1 | Caches a plan stub on first use; curbs single-use plan-cache bloat | No |
| `backup compression default` | 0 | 1 | Smaller, faster backups by default (Standard+ 2016 SP1+) | No |
| `max worker threads` | 0 (auto) | 0 (leave auto) | Auto formula scales with cores; only change with strong evidence | Yes |
| `remote admin connections` | 0 | **0 (conditional — see note)** | Local DAC is always available; enable remote only for a documented break-glass need | No |
| `default fill factor` | 0 (=100) | 0 (leave; set per-index) | A global non-100 fill factor wastes space everywhere | No |
| `blocked process threshold (s)` | 0 (off) | 5–20 (with an XEvent capture) | Surface blocking chains; pairs with **sqlserver-monitoring** | No |
| `priority boost` | 0 | **0 — never enable** | Starves OS threads; can destabilize the box and break clustering | Yes |
| `lightweight pooling` | 0 | **0 — leave off** | Fiber mode breaks CLR, linked servers, and more | Yes |

**remote admin connections (remote DAC):** keep **OFF (0)** by default — the local DAC (`sqlcmd -A` from the box console) is always available. Enable (=1) **ONLY** for a documented break-glass need, e.g. a clustered/AG instance whose active-node console is unreachable. If enabled, restrict the source to DBA jump hosts via the host firewall and audit its use.

**Edition gating:** the memory caps above are constrained by **Standard** (buffer pool 128 GB on 2016+, with separate caps for columnstore segment cache and In-Memory OLTP) and core limits (lesser of 4 sockets / 24 cores); `backup compression default` is honored on **Standard+ from 2016 SP1**. Confirm `SERVERPROPERTY('Edition')` before promising any cap the edition cannot honor.

Apply with (placeholder values — substitute your computed per-environment numbers; confirm the target instance first):

```sql
-- [CONFIG CHANGE] activates immediately on RECONFIGURE; no rollback beyond re-setting the prior value. Run against the intended instance.
EXEC sp_configure 'show advanced options', 1; RECONFIGURE;
EXEC sp_configure 'cost threshold for parallelism', 50; RECONFIGURE;
EXEC sp_configure 'max degree of parallelism', 8;      RECONFIGURE;  -- physical cores per NUMA node, cap 8
EXEC sp_configure 'optimize for ad hoc workloads', 1;  RECONFIGURE;
EXEC sp_configure 'backup compression default', 1;     RECONFIGURE;  -- Standard+ from 2016 SP1
```

`RECONFIGURE` activates a setting whose change does not need a restart (it sets `value_in_use` from `value`). Settings marked "Restart? Yes" stay pending until the service bounces — script 01 flags `value <> value_in_use` for exactly this reason. Verify 2025-specific defaults, distros, and image tags on Microsoft Learn for your build.

**Database-scoped configurations (2016+)** let you set MAXDOP, the cardinality estimator (`LEGACY_CARDINALITY_ESTIMATION`), `PARAMETER_SNIFFING`, `QUERY_OPTIMIZER_HOTFIXES`, and `OPTIMIZE_FOR_AD_HOC_WORKLOADS` per database — and per secondary replica — without an instance-wide change. A per-database `MAXDOP` overrides the instance value for that database. See the reference and script 07.

## Memory Architecture and LPIM

SQL Server divides memory among the **buffer pool** (data/index page cache — usually the largest consumer), the **plan cache**, **query workspace memory** (sort/hash grants), **lock memory**, **CLR**, **thread stacks** (2 MB/thread on x64, 512 KB on x86), and **In-Memory OLTP** memory. Deep treatment in `references/memory-and-cpu.md`.

**Max server memory sizing** — the reservation formula (the same one you should never replace with "half the RAM"):

```
max server memory = Total RAM
                    − 4 GB for the OS (more on big boxes)
                    − 1 GB per 4 GB of RAM above 16 GB (thread stacks, CLR, backups, linked servers, MTL allocations)
                    − headroom for any other services on the box (SSIS/SSRS/SSAS, agents, AV)
```

Example for 64 GB dedicated: 64 − 4 − ((64−16)/4) = 64 − 4 − 12 = **48 GB ≈ 49152 MB**. On 2019+ `max server memory` governs essentially all SQL allocations (the old "buffer pool only" caveat is gone), making the cap more accurate. Leave `min server memory` at 0 on a dedicated box; set a sensible floor only where SQL shares the box and you have seen it trimmed too hard.

**Lock Pages in Memory (LPIM)** grants the SQL service account the Windows "Lock pages in memory" privilege so the OS cannot page the buffer pool to disk under memory pressure.
- **When**: physical (non-VM) servers, or VMs where the working set is being trimmed; verify with `sys.dm_os_process_memory` (`locked_page_allocations` > 0 means LPIM is active) and `memory_utilization_percentage`.
- **Risks**: if `max server memory` is set too high with LPIM on, SQL can lock so much that the OS is starved. Always pair LPIM with a correct memory cap. The privilege itself is a security/hardening decision — cross-ref **sqlserver-security**.

## CPU, NUMA, and Scheduler Basics

- SQL Server creates one **scheduler** per logical CPU (visible online), mapping work onto worker threads cooperatively. `sys.dm_os_schedulers` shows online/offline state, the parent NUMA node, and the runnable-task queue.
- **NUMA**: on multi-socket hardware, memory is local to a socket; cross-node ("foreign") access is slower. SQL builds **memory nodes** aligned to hardware NUMA. **Automatic soft-NUMA (2016+)** splits a node/socket with **>8 physical cores** into soft nodes (ideally 8 cores each, can range 4–8; SMT/hyperthreads are not counted) for better scheduling — on by default; visible in `sys.dm_os_nodes`. Soft-NUMA changes **scheduler grouping**, not memory locality.
- **MAXDOP follows NUMA**: set it to the number of **physical** cores in a **single NUMA node**, capped at 8, as a starting point. Watch hyperthreading — count physical, not logical, cores. With ≤8 cores per node, MAXDOP ≤ that count.
- **CPU pressure** shows as `SOS_SCHEDULER_YIELD` waits, a non-empty runnable queue, and high signal-wait %. Diagnosing it is **sqlserver-monitoring's** job; configuring affinity/MAXDOP/soft-NUMA is here. Leave **CPU affinity** at default (auto) unless you are intentionally partitioning cores between instances.

## tempdb Best Practices

tempdb is recreated at every startup and is shared by every database for temp tables, table variables, sort/hash spills, the version store (RCSI/snapshot/online index/triggers/MARS), and internal worktables. Full depth in `references/storage-and-tempdb.md`.

- **File count** = `min(logical cores, 8)` data files to start; add in groups of 4 only if allocation contention persists. One log file is enough.
- **Equal size + equal autogrowth** on every data file so proportional fill spreads allocations evenly (the whole point of multiple files).
- **Pre-size** files to their expected steady state so you never autogrow during business hours; use a fixed-MB growth increment, never percent.
- **Own fast disk** — local NVMe/SSD is ideal; tempdb data loss on restart is fine, so it does not need the same durability as user data.
- **Uniform extent allocation is the default from 2016+** (the old TF 1117/1118 behavior is built in for tempdb).
- **Memory-optimized tempdb metadata (2019+)** moves the system metadata tables to memory-optimized structures, eliminating a major source of metadata contention: `ALTER SERVER CONFIGURATION SET MEMORY_OPTIMIZED TEMPDB_METADATA = ON;` (requires restart).
- **Contention symptoms**: `PAGELATCH_UP`/`PAGELATCH_EX` waits on tempdb pages `2:1:1` (PFS), `2:1:2` (GAM), `2:1:3` (SGAM). Script 04 checks the live waits and flags uneven file sizing.

## Storage Layout and Latency Targets

Deep treatment in `references/storage-and-tempdb.md`.

- **Separate volumes** for data, log, tempdb, and backups — different I/O patterns (random vs sequential), failure isolation, and independent throughput.
- **Latency targets** (from `sys.dm_io_virtual_file_stats`): **< 5 ms** for log writes, **< 10–20 ms** for data reads/writes. Sustained higher = a storage problem, not a SQL problem.
- **NTFS 64 KB allocation unit** for data/log/tempdb volumes (matches the 64 KB extent); **disable 8.3 short names** on dedicated SQL volumes.
- **Instant File Initialization (IFI)**: grant *Perform Volume Maintenance Tasks* to the SQL service account so **data-file** creation/growth/restore skips zeroing — a large speed-up. **Log files cannot use IFI**; they are always zeroed.
- **Autogrowth**: fixed MB increment (e.g., 256 MB–1 GB by DB size), never percent, and pre-size to avoid growth in business hours.
- RAID/SAN/local-NVMe/cloud-disk selection: RAID 10 for log and write-heavy data; cloud managed-disk tiering is a **sqlserver-cloud** topic.

## Key Trace Flags (configuration view)

Full catalog with versions and "became default / moved to DSC" notes in `references/platform-and-network.md`. The ones that still matter:

| TF | Effect | Note |
|---|---|---|
| 1117 / 1118 | Uniform growth / uniform extents for all DBs | **Default for tempdb in 2016+**; only for *user* DBs pre-2016 logic |
| 3226 | Suppress successful-backup messages in the error log | Stops log spam from frequent log backups; safe & common |
| 1222 | Write deadlock graphs to the error log | Prefer the `system_health` XEvent session (**sqlserver-monitoring**) |
| 4199 | Enable query-optimizer hotfixes | Now per-database via `QUERY_OPTIMIZER_HOTFIXES` (2016+) |
| 7412 | Lightweight query-profiling infrastructure | On by default 2019+; lets `sys.dm_exec_query_profiles` work |
| 460 | Return the column name in string-truncation error 2628 | Default behavior from 2019+ |
| 3625 | Hide some info from non-sysadmins ("limited") | Hardening; cross-ref **sqlserver-security** |
| 8048 | Promote NUMA-partitioned spinlocks (legacy) | Rarely needed on modern builds; diagnose first |

Set globally with `DBCC TRACEON(3226, -1);` or, preferably and durably, as a **`-T` startup parameter** so it survives restarts. Script 06 reports the live global flags via `DBCC TRACESTATUS(-1)`.

## Linux and Container Deployment

Full detail in `references/platform-and-network.md`.

- **Linux (2017+)**: supported on RHEL, Ubuntu, SLES. Configuration is via **`mssql-conf`** (or the `/var/opt/mssql/mssql.conf` file), not Windows policy — e.g. `sudo /opt/mssql/bin/mssql-conf set memory.memorylimitmb 49152`, `... set network.tcpport 1433`, traceflags, and `telemetry.customerfeedback`. HA on Linux uses **Pacemaker** (cross-ref **sqlserver-ha-clustering**); there is no classic shared-storage FCI.
- **Containers**: the official image is `mcr.microsoft.com/mssql/server`. Required env: `ACCEPT_EULA=Y`, `MSSQL_SA_PASSWORD` (inject from a secret manager / `--env-file` — `N'<generate-32+char-random-secret>'`, never a literal in the command), and `MSSQL_PID` (Developer/Express/Standard/Enterprise). **Persist `/var/opt/mssql`** on a named volume or the data is ephemeral. The 2019+ image runs as the **non-root `mssql` user (UID 10001)** — mounted-volume ownership must allow that UID, and the pod/cgroup memory limit must exceed `memory.memorylimitmb` to avoid OOM-kills. On Kubernetes use a **StatefulSet** with a PVC (and an operator for AG-based HA). Containers are excellent for dev/CI; production needs deliberate storage and HA design.

## Network, Ports, and Protocols

Full detail in `references/platform-and-network.md`.

- **TCP 1433** is the default for a default instance. **Named instances** use dynamic ports by default — pin them to a static port for firewalling.
- **SQL Server Browser** listens on **UDP 1434** to hand out named-instance ports; disable it if you pin static ports (smaller attack surface — cross-ref **sqlserver-security**).
- **Protocols**: Shared Memory (local only), TCP/IP (the network default), Named Pipes (usually disabled). Enable/disable in SQL Server Configuration Manager (Windows) or via `mssql-conf` (Linux).
- **Dedicated Admin Connection (DAC)**: a reserved scheduler/endpoint for break-glass access; enable remote use with `remote admin connections = 1` and connect with `sqlcmd -A`.
- **AG / database-mirroring endpoints** default to **TCP 5022** — endpoint configuration and firewalling are detailed in **sqlserver-ha-clustering**.
- **Encryption in transit (TLS)** for client connections is a **sqlserver-security** topic; this skill only covers the ports/protocols plumbing.

## Common Pitfalls

1. **Leaving `max server memory` unlimited** — SQL takes everything and starves the OS; paging and instability follow. Apply the formula.
2. **Cost threshold for parallelism still at 5** — trivial queries go parallel; raise to ~50 and tune.
3. **MAXDOP = 0 on a big NUMA box** — runaway parallelism and `CXPACKET`. Set to physical cores per node, cap 8.
4. **One tempdb data file** — allocation-page contention. Use `min(cores, 8)` equally sized files.
5. **Unequal tempdb files / percent growth** — proportional fill breaks; one file does all the work.
6. **No Instant File Initialization** — every data-file growth and restore stalls zeroing the file.
7. **Percentage autogrowth** — ever-larger growth events and VLF explosions; use fixed MB.
8. **LPIM with a too-high memory cap** — SQL locks the OS out of RAM. Pair LPIM with a correct cap.
9. **`priority boost = 1` / `lightweight pooling = 1`** — destabilizes the box; breaks CLR/linked servers/clustering. Leave both off.
10. **Trace flags set with `DBCC TRACEON` only** — lost on restart. Use a `-T` startup parameter for durability.
11. **Treating Linux/containers like Windows** — memory and flags go through `mssql-conf`/env vars; no Windows "Lock pages in memory" policy.
12. **Ephemeral container storage** — forgetting to persist `/var/opt/mssql` loses the databases on restart.

## Reference Files

- **`references/instance-configuration.md`** — full `sp_configure` catalog with recommended values and rationale (memory formula, MAXDOP, cost threshold, optimize for ad hoc, max worker threads, backup compression, remote admin/DAC, fill factor, blocked process threshold, priority boost/lightweight pooling = off); database-scoped configurations (MAXDOP, LEGACY_CARDINALITY_ESTIMATION, PARAMETER_SNIFFING, QUERY_OPTIMIZER_HOTFIXES, OPTIMIZE_FOR_AD_HOC_WORKLOADS); applying with RECONFIGURE; a recommended-baseline checklist.
- **`references/memory-and-cpu.md`** — memory regions (buffer pool, plan cache, query workspace, lock memory, CLR, thread stacks, In-Memory OLTP); max/min server memory sizing; Lock Pages in Memory (when/risks); NUMA & soft-NUMA, foreign memory, memory nodes; schedulers, worker threads, CPU affinity; MAXDOP relative to physical cores per node; signs of CPU pressure (cross-ref monitoring).
- **`references/storage-and-tempdb.md`** — storage layout (separate data/log/tempdb/backup), latency targets, IOPS/queue depth; NTFS 64 KB AU, disable 8.3 names; IFI (and why log files can't use it); fixed-size autogrowth; tempdb deep (file count, equal size, presize, uniform extents 2016+, memory-optimized metadata 2019+, contention symptoms); RAID levels; SAN vs local NVMe vs cloud (pointer to sqlserver-cloud).
- **`references/platform-and-network.md`** — SQL on Linux (distros, install, `mssql-conf`, filesystem, limitations, Pacemaker pointer); containers (image, env vars, persistent volumes, k8s StatefulSet/operator); trace-flag catalog with version/default notes; startup parameters (-T, -E, -g, -f, error-log path); ports & protocols (TCP 1433, dynamic ports, Browser UDP 1434, Shared Memory/TCP/Named Pipes, DAC, AG endpoint 5022); TLS pointer to sqlserver-security.

## Scripts (read-only diagnostics)

Every script is read-only, sets `SET NOCOUNT ON;`, version-guards DMVs/columns, and shows any recommended `sp_configure`/`ALTER` only as **commented-out** templates.

- **`scripts/01-instance-config-audit.sql`** — `sys.configurations` current vs recommended for the key settings, `value_in_use` vs `value` (pending RECONFIGURE), `is_advanced`; flags deviations.
- **`scripts/02-memory-config.sql`** — max/min server memory, physical RAM, `sys.dm_os_sys_memory`, `sys.dm_os_process_memory` (LPIM via `locked_page_allocations`), target-vs-total server memory counters, top memory clerks.
- **`scripts/03-cpu-numa-config.sql`** — `sys.dm_os_schedulers` (online/offline, NUMA node, runnable tasks), `sys.dm_os_nodes`/`sys.dm_os_memory_nodes`, current MAXDOP & cost threshold, affinity, soft-NUMA, logical/physical CPU and a hyperthreading hint.
- **`scripts/04-tempdb-config.sql`** — tempdb data/log files, sizes & growth, even-sizing check, file count vs core-count recommendation, memory-optimized tempdb metadata status (2019+ guard), allocation contention via live PAGELATCH waits.
- **`scripts/05-storage-layout.sql`** — files by drive/volume with size/used/autogrowth, IFI status (`sys.dm_server_services`, 2017+ note), per-file I/O latency from `sys.dm_io_virtual_file_stats`.
- **`scripts/06-trace-flags.sql`** — `DBCC TRACESTATUS(-1)` global flags captured to a temp table and selected, plus a commented reference list of common flags.
- **`scripts/07-database-scoped-config.sql`** — `sys.database_scoped_configurations` per online user DB, highlighting non-default values (MAXDOP, LEGACY_CARDINALITY_ESTIMATION, PARAMETER_SNIFFING, etc.).
- **`scripts/08-server-properties.sql`** — `SERVERPROPERTY` dump (version/level/edition/engine edition/collation/clustered/HADR/integrated-security/machine/instance), `sys.dm_os_sys_info` (cpu_count, physical_memory, start time, VM type, container type 2017+ guard), `sys.dm_os_host_info` (2017+, OS platform) guard.

**Community tools:** for a fast, prioritized config audit beyond these scripts, Brent Ozar's read-only **`sp_Blitz`** (First Responder Kit, MIT) flags risky `sp_configure` values, memory/MAXDOP/tempdb issues, and more — see the community-tools doc in **sqlserver-monitoring**. Review any third-party proc before running in production.
