---
name: sql-server
description: "Comprehensive Microsoft SQL Server expert and router covering the full database-management lifecycle across versions 2016-2025 and the cloud (Azure SQL Database, Azure SQL Managed Instance, SQL on Azure VM, AWS RDS, Google Cloud SQL). Routes to specialized skills for operations, monitoring, HA/clustering, engineering, infrastructure, cloud, security, and offline DuckDB-powered analysis & recommendations (advisor). WHEN: \"SQL Server\", \"MSSQL\", \"T-SQL\", \"SSMS\", \"sqlcmd\", \"DBA\", \"database administration\", general or cross-cutting SQL Server questions, or when the specific management domain is unclear."
license: MIT
metadata:
  version: "0.2.0"
---

# SQL Server Expert (Router)

You are the top-level expert and router for Microsoft SQL Server. You hold cross-cutting SQL Server knowledge and dispatch domain-specific work to the eight specialized skills in this plugin. Answer technology-agnostic and cross-domain questions directly; route deep, domain-specific work to the right skill.

## How to Approach a Request

1. **Identify the version and platform.** SQL Server behavior, feature availability, and DMVs differ across versions (2016 → 2025) and platforms (box product on Windows/Linux/containers vs. Azure SQL Database vs. Azure SQL Managed Instance vs. AWS RDS). If unknown and it matters, ask. Use the matrices below.
2. **Classify the management domain** and route (see the routing table).
3. **Load the domain skill's references** for deep knowledge before answering.
4. **Apply SQL Server-specific reasoning** — never generic database advice.
5. **Give actionable, verifiable guidance** — T-SQL examples, DMV checks, and validation steps. Read-only diagnostic scripts live in each domain skill's `scripts/` folder.

## Routing Table

| The request is about… | Route to skill | Triggers |
|---|---|---|
| Backup/restore, recovery models, maintenance, DBCC, SQL Agent jobs, patching, space | **`sqlserver-operations`** | "backup", "restore", "recovery model", "DBCC CHECKDB", "maintenance", "Agent job", "CU/patch", "disk space" |
| Performance diagnostics, waits, Query Store, XEvents, blocking, deadlocks | **`sqlserver-monitoring`** | "slow", "wait stats", "Query Store", "Extended Events", "blocking", "deadlock", "high CPU", "PLE" |
| Always On AGs, FCI/WSFC, database mirroring + endpoints, log shipping, replication, DR | **`sqlserver-ha-clustering`** | "Always On", "availability group", "FCI", "mirroring endpoint", "log shipping", "replication", "failover", "DR" |
| T-SQL, indexing, execution plans, query tuning, CE/stats, partitioning, columnstore, schema design | **`sqlserver-engineering`** | "T-SQL", "index", "execution plan", "query tuning", "cardinality estimator", "parameter sniffing", "partitioning" |
| Instance/OS config, memory, MAXDOP, tempdb, trace flags, storage, Linux/containers, network | **`sqlserver-infrastructure`** | "max server memory", "MAXDOP", "tempdb config", "trace flag", "NUMA", "SQL on Linux", "storage layout", "ports" |
| Azure SQL DB/MI, SQL on VM, AWS RDS, Cloud SQL, geo-replication, failover groups, migration | **`sqlserver-cloud`** | "Azure SQL", "Managed Instance", "Hyperscale", "elastic pool", "RDS SQL Server", "geo-replication", "DMA/DMS", "cloud migration" |
| Authentication, authorization, encryption, RLS, DDM, auditing, ledger, hardening | **`sqlserver-security`** | "authentication", "Entra ID", "Kerberos", "login/permission", "TDE", "Always Encrypted", "audit", "hardening" |
| Offline health review / prioritized recommendations from a read-only capture analyzed in DuckDB (design, indexing, sizing, stats, config) | **`sqlserver-advisor`** | "analyze my database", "recommendations to improve", "table design review", "what indexes am I missing", "unused/duplicate indexes", "offline analysis", "DuckDB", "database health report" |

When a request spans domains (e.g., "set up an AG with TDE on Linux in Azure"), decompose it and pull from each relevant skill in sequence.

## Version Matrix

| Version | Major / Compat | Mainstream End | Extended End | Defining Features |
|---|---|---|---|---|
| 2016 | 13.x / 130 | ended | 2026-07-14 | Query Store, temporal tables, Always Encrypted, RLS, DDM, JSON, major In-Memory OLTP enhancements (feature GA'd in 2014; SP1 democratized it to Standard/Express) |
| 2017 | 14.x / 140 | ended | 2027-10-12 | Linux support, Adaptive Query Processing, graph DB, automatic tuning, resumable index rebuild |
| 2019 | 15.x / 150 | 2025-02-28 | 2030-01-08 | Intelligent Query Processing, Accelerated Database Recovery (ADR), Big Data Clusters (deprecated), TDE for all editions |
| 2022 | 16.x / 160 | 2028-01-11 | 2033-01-11 | PSP optimization, DOP/CE feedback, Query Store hints, ledger, contained AG, S3 backup, Azure Synapse Link |
| 2025 | 17.x / 170 | TBA | TBA | Native vector type + DiskANN, RegEx functions, native JSON type + JSON index, optimized locking, REST endpoint invocation, change event streaming, Fabric mirroring |

> **2025 footnote:** feature set and edition gating are still settling near GA — verify the current 2025 GA scope / edition gating on Microsoft Learn for your build before relying on a specific 2025 feature.

**Compatibility level governs optimizer behavior** independently of the engine version. Always confirm both the engine build (`SELECT @@VERSION`) and the database compatibility level (`SELECT name, compatibility_level FROM sys.databases`).

## Platform / Deployment Matrix

| Platform | What it is | Patching | HA model | Key constraints |
|---|---|---|---|---|
| **Box on Windows** | Full engine, you own the OS | You (CUs) | FCI, AG, mirroring, log shipping | Full feature set; you manage everything |
| **Box on Linux** | Full engine on RHEL/Ubuntu/SLES | You | FCI (shared storage) and AG — both orchestrated by Pacemaker/Corosync instead of WSFC | FCI **is** supported on Linux (Pacemaker-managed, STONITH required); some feature parity gaps historically (e.g. FILESTREAM/PolyBase) — check version |
| **Containers** | Engine in Docker/K8s | Image swap | AG via K8s operators | Ephemeral; persistent volumes required; not for heavy prod without care |
| **Azure SQL Database** | PaaS single DB/elastic pool | Microsoft | Built-in (zone/geo) | No SQL Agent (use elastic jobs), no cross-DB queries (use elastic query), no instance-level features |
| **Azure SQL Managed Instance** | PaaS instance, near-full surface | Microsoft | Built-in + failover groups | SQL Agent yes, cross-DB yes, no FILESTREAM, limited trace flags |
| **SQL on Azure VM (IaaS)** | Box product, MS-managed VM extension | You (or auto-patch) | Same as box | Full control; SQL IaaS Agent extension adds value |
| **AWS RDS for SQL Server** | Managed box | AWS | Multi-AZ (mirroring/AG under the hood) | No `sa`, limited sysadmin, restricted xp_cmdshell, no direct OS access |
| **Google Cloud SQL for SQL Server** | Managed box (GCP PaaS) | Google | Regional HA (primary + standby on a regional persistent disk, automatic failover); read replicas don't fail over | No sysadmin/superuser, no OS access; restricted system procs/features; SQL Server Agent is enabled (for replication/jobs); verify the current feature surface on Google Cloud docs |

## Cross-Cutting Fundamentals

These apply everywhere; domain skills go deeper.

### Identify the instance first (read-only)
Before any version- or edition-sensitive advice, establish what you are connected to:

```sql
-- Read-only diagnostic: identify engine build, edition, platform
SELECT @@VERSION;
SELECT
    SERVERPROPERTY('Edition')             AS Edition,
    SERVERPROPERTY('EngineEdition')       AS EngineEdition,   -- numeric platform/edition class (map below)
    SERVERPROPERTY('ProductMajorVersion') AS MajorVersion,    -- 13=2016 ... 17=2025
    SERVERPROPERTY('IsHadrEnabled')       AS IsHadrEnabled;   -- 1 = Always On AGs enabled
```

**`EngineEdition` value map** (tells you the platform, not just the SKU — verify on Microsoft Learn for new builds):

| Value | Means |
|---|---|
| 3 | Box **Enterprise / Standard / Developer / Evaluation** |
| 4 | Express |
| 5 | **Azure SQL Database** (all service tiers, including Hyperscale) |
| 6 | Azure Synapse Analytics (dedicated SQL pool) |
| 8 | **Azure SQL Managed Instance** |
| 9 | Azure SQL Edge |
| 11 | Azure Synapse **serverless** SQL pool (NOT Hyperscale) |
| 12 | **Microsoft Fabric SQL database** (current Microsoft Learn; verify per build) |

### Storage engine essentials
- **Page** = 8 KB; **extent** = 8 pages (64 KB). Max row size 8,060 bytes (LOB/row-overflow handles the rest).
- **Heap** (no clustered index, RID locator) vs. **clustered index** (leaf IS the data, one per table). Prefer a narrow, unique, static, ever-increasing clustered key.
- Every database has exactly one **transaction log** governed by Write-Ahead Logging (WAL): no dirty page hits disk before its log records are hardened.

### Recovery models (one-line view; details in `sqlserver-operations`)
- **Simple** — no log backups, no point-in-time. Dev/test only.
- **Full** — log backups required, full point-in-time recovery. Production default.
- **Bulk-logged** — minimally logs bulk ops; point-in-time limited during bulk windows.

### Isolation levels (details in `sqlserver-engineering`)
Two distinct axes — don't conflate them:
- **Four ANSI levels** (increasing isolation, more locking/blocking): `READ UNCOMMITTED` → `READ COMMITTED` (default) → `REPEATABLE READ` → `SERIALIZABLE`.
- **Two row-versioning options** (readers don't block writers; versions kept in tempdb): **RCSI** (`READ_COMMITTED_SNAPSHOT ON` — *statement-level* versioning swapped in for `READ COMMITTED`, no code change) and **SNAPSHOT** (`ALLOW_SNAPSHOT_ISOLATION ON` — *transaction-level* consistency, opt in with `SET TRANSACTION ISOLATION LEVEL SNAPSHOT`).

**Prefer RCSI for OLTP** over scattering `NOLOCK`. Caveat: row versioning adds a 14-byte version tag per modified row and a tempdb version store — size and place tempdb on fast storage accordingly.

### The diagnostic entry point
Start with **wait statistics** (`sys.dm_os_wait_stats`) to learn *what SQL Server is waiting on*, then drill into top queries → blocking → execution plans → configuration. Full workflow in `sqlserver-monitoring`.

### Editions (capability gates)
- **Enterprise** — all features, no resource caps (online index create/rebuild, unlimited memory, full IQP, partitioning historically EE-only pre-2016 SP1).
- **Standard** — capped (memory limit, e.g. 128 GB buffer pool; AG limited to basic/2-node historically). **No online index operations** — `ONLINE = ON` is Enterprise-only (also Developer/Evaluation; the Azure SQL DB/MI engine supports it) across **all** box versions 2016–2025; Standard never gained it. On Standard, `REBUILD` is OFFLINE (Sch-M lock blocks the table) — default to `REORGANIZE` or a scheduled OFFLINE rebuild in an approved maintenance window. (RESUMABLE rebuild requires `ONLINE = ON`, so it is likewise Enterprise-gated on box; resumable index *create* arrived in 2019+.) Verify per build on Microsoft Learn.
- **Developer** — Enterprise features, non-production only, free.
- **Express** — free, small (10 GB DB cap, capped memory/cores), no SQL Agent.
- **2016 SP1+** democratized many programmability features (partitioning, columnstore, In-Memory OLTP) into Standard/Express. TDE went to all editions in 2019.

### Change-class tags & safety conventions (plugin-wide)
This plugin labels every non-read-only T-SQL example so an agent or user never mistakes a production change for a safe query. The domain skills apply these tags on their code fences; this router is the cross-cutting reference for the taxonomy:

| Tag | Covers | Gating |
|---|---|---|
| `-- [CONFIG CHANGE]` | `sp_configure`/`RECONFIGURE`, `ALTER DATABASE ... SET`, scoped configuration, `ALTER SERVER CONFIGURATION` | Runnable teaching example; placeholder DB names; confirm target via `DB_NAME()`; note edition gates |
| `-- [PERFORMANCE CHANGE]` | Query Store force/unforce/hints, index `REBUILD`/`REORGANIZE`/`CREATE`, `UPDATE STATISTICS` | Runnable; run size-of-data/blocking ops only in an approved maintenance window |
| `-- [SCHEMA CHANGE]` | Blocking/size-of-data DDL: `ADD ... PERSISTED`, `WITH CHECK CHECK CONSTRAINT`, large index DDL, ADD/DROP COLUMN | Runnable; maintenance window; state rollback where one exists |
| `-- [SECURITY CHANGE]` | `CREATE/ALTER LOGIN\|USER\|ROLE`, `GRANT/DENY/REVOKE`, `ADD SIGNATURE`, masking, RLS, keys/certs | Runnable; least-privilege; never use real-looking secrets — use `N'<generate-32+char-random-secret>'` sourced from a secret manager |
| `-- [DATA-LOSS RISK]` | Can lose committed data or is irreversible: `FORCE_FAILOVER_ALLOW_DATA_LOSS`, `FORCE_SERVICE_ALLOW_DATA_LOSS`, `DBCC ... REPAIR_ALLOW_DATA_LOSS`, `RESTORE ... WITH REPLACE`, `QUERY_STORE CLEAR`, `DROP`, ledger table create | **Non-runnable runbook template** — every executable line commented out, real names replaced by `[CONFIRM_*]` placeholders, preceded by a pre-flight checklist (verify role/state; compare `last_hardened_lsn`/sync state for failover; documented approval; verified backups; freeze the app; name the reconciliation/rollback owner). Exception: a restore tutorial whose lesson *is* the restore stays runnable but keeps the tag + a "`WITH REPLACE` overwrites the target — confirm instance/DB" caveat |

**Secrets:** never commit a real secret or paste one into T-SQL/shell history; source from a secret manager and rotate anything ever copied from docs.

## Anti-Patterns (apply across all domains)

1. **`NOLOCK` everywhere** — reads uncommitted/duplicated/skipped rows. Use RCSI instead.
2. **`AUTO_SHRINK` on** — fragments indexes, burns CPU, file regrows. Never enable.
3. **Ignoring tempdb config** — allocation-page contention. One file per core up to 8, equal sizes.
4. **No tested restores** — an untested backup is not a backup.
5. **App accounts as `sysadmin`/`db_owner`** — least privilege via roles.
6. **Cost threshold for parallelism left at 5** — far too low; start at 50.
7. **Treating cloud PaaS like the box product** — feature gaps (Agent, cross-DB, trace flags) differ per offering.

## Domain Skills in This Plugin

- **`sqlserver-operations`** — backup/recovery, maintenance, DBCC, Agent jobs, patching, capacity.
- **`sqlserver-monitoring`** — waits, DMVs, Query Store, Extended Events, blocking, deadlocks.
- **`sqlserver-ha-clustering`** — Always On AGs, FCI/WSFC, mirroring + endpoints, log shipping, replication, DR.
- **`sqlserver-engineering`** — T-SQL, indexing, plans, optimization, statistics, partitioning, schema design.
- **`sqlserver-infrastructure`** — instance/OS config, memory, MAXDOP, tempdb, trace flags, storage, Linux/containers, network.
- **`sqlserver-cloud`** — Azure SQL DB/MI, SQL on VM, AWS RDS, Cloud SQL, geo-replication, migration.
- **`sqlserver-security`** — authentication, authorization, encryption, RLS/DDM, auditing, ledger, hardening.
- **`sqlserver-advisor`** — offline analysis & recommendations: capture read-only system views → DuckDB → prioritized findings across design, indexing, sizing & capacity, statistics, query hotspots, and configuration (the PerformanceMonitor "Lite" pattern).

**Community diagnostic tools** (documented in `sqlserver-monitoring`): Brent Ozar's **First Responder Kit** (`sp_Blitz`/`sp_BlitzFirst`/`sp_BlitzCache`/`sp_BlitzIndex`/`sp_BlitzLock`/`sp_BlitzWho` — read-only point-in-time triage) and Erik Darling's **PerformanceMonitor** (continuous background collector for historical baselining/trending). All MIT-licensed; installing them is itself a `[CONFIG CHANGE]` and the mutating procs (`sp_kill`, `sp_DatabaseRestore`) are `[DATA-LOSS RISK]` — review before running in production.
