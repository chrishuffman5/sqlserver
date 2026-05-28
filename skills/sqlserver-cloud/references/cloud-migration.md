# Cloud Migration — Reference

Migrating SQL Server to the cloud is **assess → choose target → choose method → cut over → validate**. The most common failure mode is skipping assessment and discovering a blocking feature (FILESTREAM, cross-DB references, an unsupported trace flag) *after* a failed cutover. Assess first, always.

---

## 1. Assessment First

### Data Migration Assistant (DMA)
The free, run-this-first tool. DMA does two things:

- **Compatibility / feature-parity assessment** — points a source database at a chosen target (Azure SQL DB, MI, or SQL on VM) and reports:
  - **Migration blockers** — features unsupported at the target (e.g. cross-DB references and FILESTREAM block Azure SQL DB).
  - **Behavior changes / deprecated features** — things that work but change behavior at the higher compat level.
- **SKU recommendation** — consumes a perfmon capture of the source and recommends a service tier/size (vCores, tier, storage) for the target. Right-sizing input, not a guarantee — validate after migration.

DMA also performs schema + data migration for smaller workloads, but for production prefer Azure DMS or a backup/replication method.

### Azure Migrate
Discovery and business-case tooling for a **portfolio** — inventories on-prem SQL estates, runs Azure SQL assessments at scale, and produces cost/right-sizing reports. Use it when migrating many servers rather than one database.

### What to capture during assessment
- Engine version & **compatibility level** of every database.
- **Database sizes**, file counts, growth rates → drives target tier and method.
- **Server-level dependencies**: logins (and their SIDs), Agent jobs, linked servers, credentials, certificates/keys, server triggers, Resource Governor config, mail profiles.
- **Cross-database dependencies** (blocks Azure SQL DB).
- **Unsupported features** for the chosen target (see §4).
- Workload telemetry (CPU/IO/memory P95) for SKU sizing.

---

## 2. Migration Method Matrix

| Method | Valid targets | Downtime profile | Mechanism / notes |
|---|---|---|---|
| **Azure DMS — offline** | Azure SQL DB, MI, SQL-on-VM | Outage = full data copy time | Managed migration service; one-shot copy. Simple, but downtime scales with size. |
| **Azure DMS — online** | Azure SQL DB, MI, SQL-on-VM | **Minimal** (cutover only) | Continuous sync of changes after initial load; cut over when caught up. |
| **Backup/restore to URL** | **MI**, SQL-on-VM | Outage = restore time | `COPY_ONLY` backup → Azure Blob → `RESTORE ... FROM URL`. Native, reliable for MI. |
| **BACPAC export/import** | **Azure SQL DB** (also MI) | Outage during export+import | Schema+data package via SqlPackage. **Not transactionally consistent** unless source is read-only/quiesced. Best for small/static DBs. |
| **Managed Instance link** | **MI** | **Near-zero** | DAG-based near-real-time replication; SQL 2022 (2016+ source w/ CUs); controlled, bidirectional cutover. Best low-downtime path to MI. |
| **Log Replay Service (LRS)** | **MI** | Cutover only | Continuously restore a full+log backup chain from Blob onto MI; manual cutover. The "no MI link available" near-zero alternative. |
| **Transactional replication** | Azure SQL DB (subscriber), MI, VM | Near-zero | Publisher stays on-prem; subscriber in cloud. Good for phased/partial moves and table subsets. |
| **Distributed AG** | **MI**, SQL-on-VM | Near-zero | Stretch an existing on-prem AG to a cloud replica, sync, then fail over. Needs an existing AG. |
| **Native backup/restore to S3** | **AWS RDS** (also EC2) | Outage = restore time | `rds_backup_database` / `rds_restore_database` (via an **option group**) move native `.bak` files to/from Amazon S3 — the primary path into/out of RDS. EC2 is the box engine (any on-prem method). |
| **AWS DMS** (full-load + CDC) | **AWS RDS**, EC2 | **Minimal** (online CDC) | Managed migration/replication service; full load then change-data-capture for low-downtime cutover. Heterogeneous-capable; for homogeneous SQL→SQL, S3 backup/restore is often simpler. |
| **GCP Database Migration Service (DMS)** | **Cloud SQL for SQL Server** | Varies (continuous option) | Google's managed migration service; can do continuous migration from on-prem/other clouds into Cloud SQL. Cloud SQL also supports import from a SQL `.bak` in Cloud Storage. |
| **Detach/attach, import/export wizard, SSIS, bcp** | VM/EC2 (attach), any (data tools) | Varies | Tactical/partial; attach only works on the box engine (VM/EC2), not PaaS. |

### Choosing by target
- **→ Azure SQL Database:** BACPAC (small/static) or **Azure DMS online** (larger, low downtime), or transactional replication for phased. No native backup/restore — the engine won't accept a `.bak`.
- **→ Managed Instance:** **MI link** (lowest downtime, 2022+), **native backup/restore to URL** (simplest), **LRS** (chain restore), **Azure DMS**, or **distributed AG**.
- **→ SQL on VM:** **backup/restore to URL**, distributed AG, log shipping, or Azure DMS — it's the box engine, so almost any on-prem method works.
- **→ AWS RDS for SQL Server:** **native backup/restore to/from S3** (`rds_backup_database` / `rds_restore_database` via an option group — simplest for homogeneous SQL→SQL), or **AWS DMS** (full-load + CDC) for lower-downtime cutover. RDS won't accept a restore to local disk. (RDS **Custom** / **EC2** are the box engine and take any on-prem method.)
- **→ Google Cloud SQL for SQL Server:** **GCP Database Migration Service** (continuous migration) or **import a `.bak` from Cloud Storage**; export back out the same way. No OS/local-disk restore path.

---

## 3. Downtime vs Complexity Trade-off

```
Lowest downtime, highest setup complexity
        │  MI link / Distributed AG / Azure DMS online / Transactional replication
        │  Log Replay Service (online sync, manual cutover)
        │  Backup/restore to URL (outage = restore time)
        │  BACPAC export/import (outage = export+import)
        ▼  Detach/attach, bcp (smallest DBs, simplest, most downtime)
Highest downtime, lowest setup complexity
```

Pick the simplest method whose downtime fits the business RTO. Don't engineer a near-zero-downtime DAG for a 2 GB database that can tolerate a 20-minute BACPAC.

---

## 4. Pre-Migration Blockers (per target)

Resolve these *before* cutover — they are the features DMA flags.

**Block Azure SQL Database (must refactor or pick MI/VM instead):**
- Cross-database references / 3-part names / cross-DB transactions.
- SQL Agent jobs (no Agent — re-platform to Elastic Jobs).
- Linked servers; CLR; Service Broker (cross-DB); FILESTREAM/FileTable.
- Instance-level objects (server triggers, logins as instance objects, Resource Governor).
- `USE`-style database switching in code.

**Block / restrict Azure SQL Managed Instance:**
- FILESTREAM/FileTable; buffer pool extension; most trace flags.
- Unsupported `sp_configure` options; certain replication roles.
- **Instance (server) collation is set at MI creation and immutable after** (`tempdb` follows it; default is `SQL_Latin1_General_CP1_CI_AS`) — match the source instance collation when you create the MI, or plan special handling.
- Cross-instance Service Broker; OS-dependent features (`xp_cmdshell` to host, file shares).

**Block AWS RDS / Cloud SQL:**
- Anything needing `sa`, OS access, or host scheduling.
- `xp_cmdshell` (off by default), unsupported replication/log-shipping topologies.
- FILESTREAM/FileTable, certain trace flags, custom backup-to-local.

**SQL on VM:** essentially no engine blockers (it's the box product) — blockers are operational (you must rebuild HA, storage, backups).

---

## 5. Post-Migration Validation

A migration isn't done at cutover — validate:

1. **Compatibility level** — confirm it's set deliberately (often you migrate at the old compat level, then raise it after testing under Query Store).
2. **Query-performance regression** — capture Query Store before *and* after; the higher compat level / new CE can regress plans. Use Query Store **forced plans** or compat-level pinning to mitigate. (See `sqlserver-monitoring` / `sqlserver-engineering`.)
3. **Server-level objects recreated at target:**
   - **Logins & SIDs** — recreate logins and **re-map orphaned users** (SID mismatch is the classic post-restore failure). Use contained users where possible to avoid the problem.
   - **SQL Agent jobs** — recreate on MI/VM/RDS; re-platform to Elastic Jobs on Azure SQL DB.
   - **Linked servers, credentials, certificates/keys** (incl. TDE certs — restore the cert *before* the DB or the restore fails), server triggers, mail profiles, Resource Governor.
4. **TDE / encryption** — ensure keys are present at the target (Key Vault / service-managed) and TDE state matches.
5. **Connectivity & app config** — connection strings (failover-group listener vs server name), firewall/private-endpoint rules, redirect vs proxy policy, retry logic for transient PaaS faults.
6. **Functional smoke test** — run the application's critical paths; verify Agent jobs/Elastic Jobs fire; verify cross-DB queries (MI/VM) resolve.
7. **DR posture** — set up the failover group / geo-replication / Multi-AZ at the target and test a failover.

---

## 6. Choosing the Right Target — Decision Matrix

| If the source needs… | …then target |
|---|---|
| OS access, FILESTREAM, full feature set, version pinning | **SQL on Azure VM** (or RDS Custom on AWS) |
| SQL Agent, cross-DB queries, CLR, Service Broker, linked servers (lift-and-shift an instance) | **Azure SQL Managed Instance** |
| A single/independent cloud-native database, elastic scale, serverless economics | **Azure SQL Database** |
| >4 TB (up to 128 TB; verify the current limit on Microsoft Learn), near-instant backup/restore, read scale-out | **Azure SQL Database — Hyperscale** |
| Many small multi-tenant DBs peaking at different times | **Azure SQL DB — Elastic Pool** |
| Least-effort managed SQL on AWS / GCP | **AWS RDS** / **Cloud SQL** |

Default to the **most managed** option that still satisfies the feature requirements: MI for instance parity, SQL DB for cloud-native scale, VM/RDS only when control or unsupported features force it.

> Run `scripts/05-migration-readiness.sql` against the **on-prem source** to inventory compat level, deprecated-feature use, Azure-SQL-DB-blocking features, sizes, collation, and the server-level objects to recreate at the target.
