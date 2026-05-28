---
name: sqlserver-cloud
description: "SQL Server cloud offerings and migration: Azure SQL Database (DTU/vCore, elastic pools, serverless, Hyperscale), Azure SQL Managed Instance, SQL Server on Azure VM, AWS RDS for SQL Server, and Google Cloud SQL — including feature-parity differences, geo-replication, auto-failover groups, and migration tooling (Data Migration Assistant, Azure DMS, Managed Instance link, log replay, BACPAC, backup/restore to URL). WHEN: \"Azure SQL\", \"Azure SQL Database\", \"Managed Instance\", \"SQL MI\", \"Hyperscale\", \"elastic pool\", \"serverless SQL\", \"DTU\", \"vCore\", \"SQL Server on Azure VM\", \"SQL IaaS\", \"AWS RDS SQL Server\", \"RDS\", \"Cloud SQL\", \"geo-replication\", \"failover group\", \"DMA\", \"Azure DMS\", \"MI link\", \"cloud migration\", \"BACPAC\", \"PaaS SQL\", \"which Azure SQL\"."
license: MIT
metadata:
  version: "0.1.0"
---

# SQL Server in the Cloud

You are the cloud-offerings and migration specialist for Microsoft SQL Server. This skill covers the *deployment platforms* SQL Server runs on outside an on-prem box: the Azure PaaS family (Azure SQL Database, Azure SQL Managed Instance), SQL Server on Azure VM (IaaS), and the third-party managed offerings (AWS RDS for SQL Server, Google Cloud SQL for SQL Server). It also owns **cloud migration** end to end.

The single biggest source of confusion in this domain is **which feature exists in which offering**. Azure SQL Database is *not* a SQL Server instance — it is a database-scoped PaaS service with major surface-area gaps. Managed Instance is *near-full* instance parity. SQL on a VM and AWS RDS are the *actual box engine* with different operational guard-rails. Treating one like another is the root cause of most failed migrations and cost surprises. Be precise.

Engine internals (storage engine, optimizer, T-SQL, indexing, AG mechanics) are NOT duplicated here — cross-reference the sibling skills:
- `sqlserver-engineering` — T-SQL, indexing, plans, statistics, partitioning.
- `sqlserver-operations` — backup/restore mechanics, maintenance, DBCC, Agent jobs.
- `sqlserver-monitoring` — waits, DMVs, Query Store, Extended Events.
- `sqlserver-ha-clustering` — on-prem AG/FCI/WSFC, mirroring, log shipping, replication.
- `sqlserver-infrastructure` — instance/OS config, memory, MAXDOP, tempdb, storage, Linux.
- `sqlserver-security` — auth (incl. Entra ID), TDE, Always Encrypted, auditing, hardening.

## How to Approach a Cloud Request

**Always pin down WHICH offering first.** Almost every answer changes based on it. If the user says "Azure SQL" ask whether they mean *Azure SQL Database* (PaaS single DB / elastic pool) or *Azure SQL Managed Instance* — these are different products with different feature sets, pricing, and connection models.

1. **Identify the offering** — Azure SQL DB vs MI vs SQL-on-VM vs AWS RDS vs Cloud SQL. When diagnosing a live system, confirm with the canonical detection query:

   ```sql
   -- Read-only diagnostic: platform / edition / Azure SQL DB tier detection
   SELECT
       SERVERPROPERTY('EngineEdition')                         AS engine_edition,   -- routing key (below)
       SERVERPROPERTY('Edition')                               AS edition,
       DATABASEPROPERTYEX(DB_NAME(), 'Edition')                AS db_edition,        -- 'Hyperscale' on HS
       DATABASEPROPERTYEX(DB_NAME(), 'ServiceObjective')       AS service_objective; -- 'HS_*' on HS, 'GP_*','BC_*', etc.
   ```

   `EngineEdition` values (verify the current list on Microsoft Learn — [SERVERPROPERTY](https://learn.microsoft.com/en-us/sql/t-sql/functions/serverproperty-transact-sql)):

   | EngineEdition | Offering |
   |---|---|
   | `1` | Personal/Desktop (legacy) |
   | `2` | Standard box engine (SQL-on-VM, RDS/Cloud SQL Standard, on-prem) |
   | `3` | Enterprise/Developer/Evaluation box engine (SQL-on-VM, AWS RDS Enterprise, on-prem) |
   | `4` | Express box engine |
   | `5` | **Azure SQL Database** — single DB / elastic pool, **including Hyperscale** |
   | `6` | Azure Synapse Analytics (dedicated SQL pool) |
   | `8` | **Azure SQL Managed Instance** |
   | `9` | Azure SQL Edge |
   | `11` | Azure Synapse serverless SQL pool |
   | `12` | Microsoft Fabric SQL database |

   **Hyperscale does NOT have its own EngineEdition** — it reports `5` (Azure SQL Database). Differentiate Hyperscale via `DATABASEPROPERTYEX(DB_NAME(),'Edition') = 'Hyperscale'` or `service_objective LIKE 'HS\_%'`. Microsoft Fabric SQL Database shares the Azure SQL Database engine but reports its **own** `EngineEdition = 12` per current Microsoft Learn (Microsoft's guidance here has shifted over time — verify for your build).
2. **Identify the intent** — provisioning/sizing, HA/DR design, feature-gap troubleshooting, cost optimization, or migration. Migration is the heaviest sub-domain → read `references/cloud-migration.md`.
3. **Load the offering's reference** for depth (see Reference Files below).
4. **Reason in cloud terms** — the SLA, the HA model, who patches, what DMVs exist, and the cost levers are all offering-specific. Never give on-prem advice (e.g. "set max server memory", "add tempdb files", "configure WSFC quorum") for a PaaS offering where it does not apply.
5. **Verify** — point the user at the matching diagnostic script in `scripts/`, each of which guards on `EngineEdition` and tells them if they ran it on the wrong platform.

## Offering Comparison Matrix

| Dimension | Azure SQL Database | Azure SQL Managed Instance | SQL on Azure VM | AWS RDS for SQL Server |
|---|---|---|---|---|
| What it is | PaaS single DB / elastic pool | PaaS instance, near-full surface | IaaS — full box engine on a VM | Managed box engine |
| Surface area | Database-scoped only; many gaps | ~Full instance parity | 100% (it *is* SQL Server) | Box engine, guard-railed |
| SQL Server Agent | **No** (use Elastic Jobs) | **Yes** | Yes | Yes (SQL Agent jobs work; some job types restricted) |
| Cross-database queries | **No** (use Elastic Query / external tables) | **Yes** (within the instance) | Yes | Yes (within the instance) |
| Instance-level objects | No (logical `master`, no linked servers*) | Yes (linked servers, CLR, Service Broker within instance) | Yes | Limited (linked servers via option group; no Service Broker cross-instance) |
| Max data size | 4 TB (GP/BC vCore) / 128 TB (Hyperscale)* | Scales with vCores/hardware: GP up to 16 TB (32 TB next-gen); BC up to 16 TB (premium-series, enough vCores)* | VM disk limits (tens of TB, up to PB w/ pools) | 16 TB per instance |
| HA model | Built-in; zone-redundant; geo-replication / failover groups | Built-in (GP = remote storage + Azure SR; BC = AG-like); failover groups | You build it: AG/FCI + Cloud Witness / Azure shared disks / S2D | Multi-AZ (synchronous, mirroring/AG under the hood) |
| Patching | Microsoft (transparent) | Microsoft (transparent, maintenance windows) | You (or SQL IaaS Agent auto-patch) | AWS (maintenance windows) |
| OS / `sa` access | None | None (but full T-SQL admin) | Full RDP / `sa` / root | No OS/RDP; limited admin login (no `sa`) |
| Backups | Automatic, PITR + LTR | Automatic, PITR + LTR; restore from URL | You own them (or auto-backup extension) | Automatic snapshots; native backup/restore to S3 |
| Typical use case | New cloud-native apps, SaaS multi-tenant, elastic scale | Lift-and-shift of instances needing Agent/cross-DB/CLR | Apps needing OS access, unsupported features, full control | AWS-resident apps wanting managed SQL with least effort |

\* Azure SQL DB has no linked servers; the equivalent is Elastic Query / external data sources, which are far more limited.

\* Max-size figures move (cloud limits change quarterly). Hyperscale single-DB max is currently **128 TB** (elastic-pool DBs lower); MI Business Critical reaches 16 TB only on premium-series hardware with sufficient vCores in supported regions (otherwise 5.5 TB), and on Standard-series caps at 4 TB. **Verify the current value on Microsoft Learn for your tier/region.**

## The Offerings in Brief

### Azure SQL Database (PaaS) — `EngineEdition = 5`
Database-as-a-service. You get a *logical server* (a connection endpoint and security boundary, **not** an instance) hosting one or more databases or elastic pools.
- **Purchasing models:** DTU (bundled compute+storage+IO, tiers Basic/Standard/Premium) or **vCore** (decoupled, recommended) with tiers **General Purpose**, **Business Critical**, and **Hyperscale**.
- **Serverless** compute (GP/Hyperscale): auto-scales vCores within a range and **auto-pauses** when idle (billed for storage only) — great for intermittent workloads.
- **Elastic pools** share a resource budget across many databases (ideal for SaaS multi-tenant where DBs peak at different times).
- **Hyperscale** decouples compute from a distributed storage layer (page servers + log service) for databases up to **128 TB** (verify the current GA limit on Microsoft Learn — cloud limits change quarterly), near-instant backups, fast restore, and multiple read replicas.
- **Gaps:** no SQL Agent (→ Elastic Jobs), no `USE`/cross-DB queries (→ Elastic Query), no instance objects, no FILESTREAM/Service Broker cross-DB, partial DMV surface, logical `master`.
- Deep dive: `references/azure-sql-database.md`.

### Azure SQL Managed Instance (PaaS) — `EngineEdition = 8`
A fully managed *instance* with near-100% on-prem surface area — the lift-and-shift target.
- **Tiers:** General Purpose (remote storage), Business Critical (local SSD + built-in AG, includes a free readable secondary), and **Next-gen General Purpose** (flexible storage scaling, separately provisioned IOPS, changed IO billing). Max storage scales with vCores and hardware generation (see `references/azure-managed-instance.md`) — not a flat number.
- **Has** SQL Agent, cross-database queries, CLR, Service Broker (within the instance), linked servers, distributed transactions (within MI), global temp tables.
- **vNet-injected** (private by default; optional public endpoint). **Auto-failover groups** for DR.
- **MI link** (SQL Server 2022, and 2016+ as source via patches) gives near-real-time replication from on-prem SQL to MI for migration, read offload, and DR.
- **Not supported:** FILESTREAM/FileTable, buffer pool extension, most trace flags, some instance-level features. See `references/azure-managed-instance.md`.

### SQL Server on Azure VM (IaaS) — box engine, `EngineEdition` 2/3/4
The real box product on a Microsoft-managed VM. You own the OS, patching, HA, and storage layout. The **SQL IaaS Agent extension** adds automated patching, automated backup to Azure storage, and Azure Key Vault integration. HA is whatever you build: AG or FCI with a **Cloud Witness**, **Azure shared disks**, or **Storage Spaces Direct (S2D)**. Licensing via **Azure Hybrid Benefit (AHB)** or pay-as-you-go (PAYG). See `references/sql-on-iaas-and-other-clouds.md`.

### AWS RDS for SQL Server — managed box
Managed SQL Server on AWS. **Multi-AZ** provides synchronous HA (mirroring historically, AG for newer/Enterprise). Key constraints: **no `sa`** (you get a limited master-style admin login), **no OS/RDP access**, `xp_cmdshell` off by default, configuration via **parameter groups** and feature enablement via **option groups**, native **backup/restore to S3** (and the only path for moving native backups in/out), **read replicas**. See `references/sql-on-iaas-and-other-clouds.md`.

### Google Cloud SQL for SQL Server — managed (brief)
Managed SQL Server on GCP with **regional HA** (a standby in another zone with automatic failover), **read replicas**, and a feature-gap profile similar in spirit to RDS (no OS access, limited admin). Covered briefly in `references/sql-on-iaas-and-other-clouds.md`.

## HA / DR in the Cloud

- **Within a region:** Azure SQL DB and MI Business Critical replicate synchronously across a local cluster automatically. Enable **zone redundancy** to spread replicas across availability zones (Premium/BC and Hyperscale support it) for higher SLA.
- **Across regions:** Use **active geo-replication** (Azure SQL DB only; up to 4 readable secondaries, manual failover) or **auto-failover groups** (Azure SQL DB *and* MI; group of databases, a read-write + read-only **listener endpoint**, and automatic failover). On failover, the failover-group **listener** redirects clients without a connection-string change — the read-write listener follows the new primary. Geo-replication failover is per-database and requires the app to chase the new server name unless fronted by a failover group.
- **Hyperscale** adds HA replicas and named replicas for read scale-out, plus zone redundancy.
- **SQL on VM / RDS:** classic AG/FCI (you build it) or RDS Multi-AZ (AWS builds it). Cross-region on RDS = read replicas or cross-region snapshot copy; on VM = stretch the AG to a second region.

Detailed geo-replication vs failover-group behavior lives in `references/azure-sql-database.md` and `references/azure-managed-instance.md`.

## Target-Selection Decision Tree

```
Need full OS access, FILESTREAM/FileTable, unsupported features,
3rd-party agents on the box, or a non-standard config?
   └─ YES → SQL Server on Azure VM (IaaS)   [or AWS RDS Custom if AWS-bound]
   └─ NO ↓

Need SQL Agent, cross-database queries, CLR, Service Broker,
linked servers, or instance-level objects — i.e. lift-and-shift an instance?
   └─ YES → Azure SQL Managed Instance
   └─ NO ↓

Single database (or many independent DBs) with a cloud-native app,
elastic scaling, or huge size / very fast restore needs?
   └─ Huge (>4 TB) or fast-restore/read-scale  → Azure SQL Database Hyperscale
   └─ Intermittent / dev-test / spiky          → Azure SQL Database Serverless
   └─ Many small multi-tenant DBs              → Azure SQL Database Elastic Pool
   └─ Steady single DB                         → Azure SQL Database (vCore GP/BC)

(AWS-resident org wanting least-effort managed SQL) → AWS RDS for SQL Server
(GCP-resident org)                                  → Google Cloud SQL for SQL Server
```

Rule of thumb: **VM** for control, **MI** for instance-level parity, **SQL DB** for cloud-native scale and least management. Pick the most managed option that still meets your feature requirements.

## Migration Methods Overview

Assess first, then choose a method by target and downtime tolerance. Full matrix and pre/post checklists in `references/cloud-migration.md`.

| Method | Target | Downtime | Notes |
|---|---|---|---|
| **Data Migration Assistant (DMA)** | (assessment) | — | Compatibility + feature-parity report, SKU recommendation. Run first. |
| **Azure DMS** (online/offline) | SQL DB, MI, VM | Online = minimal | Managed service; online uses continuous sync. |
| **Backup/restore to URL** | MI, VM | Outage = restore time | `BACKUP/RESTORE ... TO URL`; native to MI from on-prem. |
| **BACPAC** (export/import) | Azure SQL DB | Outage during export/import | Schema+data package; not transactionally consistent unless DB is quiesced. |
| **Managed Instance link** | MI | Near-zero | SQL 2022 (2016+ source w/ updates); near-real-time, controlled cutover. |
| **Log Replay Service (LRS)** | MI | Cutover only | Restore full+log chain from URL continuously; manual cutover. |
| **Transactional replication** | SQL DB (subscriber), MI, VM | Near-zero | Publisher stays on-prem; good for phased moves. |
| **Distributed AG** | MI, VM | Near-zero | Stretch an on-prem AG to the cloud replica, then fail over. |

## Common Pitfalls

1. **Treating PaaS like the box product.** No `xp_cmdshell`, no `USE` across DBs on SQL DB, no `sp_configure 'max server memory'`, no adding tempdb files on PaaS. Don't prescribe on-prem fixes for PaaS symptoms.
2. **Confusing SQL DB with MI.** "Azure SQL" is ambiguous. SQL Agent and cross-DB queries are the usual deciding features — they exist on MI, not SQL DB.
3. **DMV / surface gaps on SQL DB.** Many server-scoped DMVs and `sys.*` views are absent or behave differently; `sys.dm_db_resource_stats` replaces a lot of the on-prem telemetry. Don't assume an on-prem query runs.
4. **Cost surprises.** vCore Business Critical and Hyperscale are pricey; serverless saves money only for *intermittent* workloads (a 24×7 DB on serverless costs more). Elastic pools save money only when DBs peak at *different* times. Geo-secondaries and zone redundancy add cost.
5. **DTU when vCore fits better.** DTU is opaque and hard to right-size; prefer vCore for new work and for AHB licensing benefit.
6. **Migration without assessment.** Skipping DMA hides blocking features (FILESTREAM, cross-DB refs, unsupported trace flags) that surface only after a failed cutover.
7. **Forgetting server-level objects.** Logins/SIDs, Agent jobs, linked servers, certificates, and credentials don't travel with a database-level migration — they must be recreated/remapped at the target.

## Reference Files

- `references/azure-sql-database.md` — purchasing models & tiers, serverless, elastic pools, Hyperscale architecture & limits, built-in HA / zone redundancy / read scale-out, geo-replication vs failover groups (listener/endpoint behavior), backups/PITR/LTR, Elastic Jobs, the feature gaps & workarounds, DTU↔vCore sizing, connection/auth model.
- `references/azure-managed-instance.md` — architecture & tiers, instance pools, surface-area parity table, vNet/connectivity, backups/PITR/LTR & restore from URL, auto-failover groups, the MI link feature, the limitations list, and cost levers.
- `references/sql-on-iaas-and-other-clouds.md` — SQL on Azure VM (IaaS Agent extension, storage best practices, HA options, licensing), AWS RDS for SQL Server (Multi-AZ, the limited-admin model, option/parameter groups, S3 backup, read replicas, what you can't do), Google Cloud SQL (brief), and when to choose IaaS over PaaS.
- `references/cloud-migration.md` — assessment (DMA, Azure Migrate), the migration-method matrix per target, downtime vs complexity trade-offs, pre-migration blockers per target, post-migration validation, and a target-selection decision matrix.

## Scripts

Read-only diagnostics. Each carries a standard header, sets `SET NOCOUNT ON;`, and **guards on `SERVERPROPERTY('EngineEdition')`** so it tells you immediately if it was run on the wrong platform.

- `scripts/01-azure-sql-db-health.sql` — **Azure SQL Database** (EngineEdition 5). Resource utilization (`sys.dm_db_resource_stats` last hour + `sys.resource_stats`), DTU/CPU/IO/memory/worker/session percentages, DB size vs MAXSIZE, current service objective/edition, connection count.
- `scripts/02-managed-instance-checks.sql` — **Azure SQL Managed Instance** (EngineEdition 8). Instance resource stats (`sys.server_resource_stats`), vCores/tier, reserved vs used storage, tempdb config, Agent job status pointer, recent backups, errorlog access.
- `scripts/03-geo-replication-status.sql` — **Azure SQL DB / MI**. Geo-replication link status & lag (`sys.dm_geo_replication_link_status`, `sys.geo_replication_links`) and failover-group readiness, with offering guards.
- `scripts/04-iaas-cloud-readiness.sql` — **SQL on Azure VM / AWS RDS** (box engine, EngineEdition 2/3/4). Platform/edition confirmation, Instant File Initialization, data/log file latency vs cloud-disk suitability, tempdb config, AG/witness presence, max-memory sanity vs VM size — framed as cloud-IaaS hygiene.
- `scripts/05-migration-readiness.sql` — **on-prem source** being assessed for the cloud. Compatibility level, deprecated-feature counters, Azure-SQL-DB-blocking features (cross-DB references, CLR, FILESTREAM, Service Broker, Agent jobs, linked servers, server logins), DB size/file count, non-default collation, and the instance-level object inventory to recreate at the target. **Run Sections 3a–3d in EACH database** (they assess the current DB only); Sections 1/2/4/5/6 are server-wide.

For continuous baselining/trending against cloud targets (Erik Darling **PerformanceMonitor** supports MI and AWS RDS; Azure SQL Database via its Lite edition) and ad-hoc point-in-time triage with the Brent Ozar First Responder Kit, see the community-tools guidance in `sqlserver-monitoring` — review before running, consistent with the bundled-script policy.
