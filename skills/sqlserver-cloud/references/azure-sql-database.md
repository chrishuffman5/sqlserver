# Azure SQL Database (PaaS) — Reference

Azure SQL Database is **database-as-a-service**, not an instance. The unit you provision is a *logical server* — a connection endpoint (`<name>.database.windows.net`) and a security/firewall boundary — that hosts one or more **single databases** or **elastic pools**. There is no OS, no instance to configure, no SQL Agent, and the `master` database is *logical* (it tracks logins/firewall rules for the server but is not a real `master` you can write to). `EngineEdition = 5`.

This is the offering people most often misuse by assuming it behaves like the box product. It does not. Read the gaps section before prescribing anything.

---

## 1. Purchasing Models & Service Tiers

There are two purchasing models. **Prefer vCore for new work** — it is transparent, supports Azure Hybrid Benefit, and maps cleanly to on-prem sizing.

### DTU model (legacy, bundled)
A **Database Transaction Unit** is an opaque blended measure of CPU + memory + IO. You buy a tier and a DTU count; you cannot tune the mix.

| Tier | DTU range | Max size | Typical use |
|---|---|---|---|
| **Basic** | 5 DTU | 2 GB | Dev/test, tiny apps |
| **Standard** | 10–3000 DTU (S0–S12) | up to 1 TB | General-purpose production |
| **Premium** | 125–4000 DTU (P1–P15) | up to 4 TB | IO-intensive, low-latency, local SSD, higher availability |

DTU is hard to right-size because you cannot see which resource is the bottleneck. Migrate to vCore when in doubt.

### vCore model (recommended)
Decouples **compute** (vCores + memory), **storage**, and **IO**, and exposes hardware generations (e.g. standard-series / premium-series). Tiers:

| Tier | Storage / architecture | HA | Max size | When to use |
|---|---|---|---|---|
| **General Purpose (GP)** | Remote premium storage (compute and storage separated) | Local redundancy; optional zone redundancy | 4 TB | Most production workloads; budget-balanced |
| **Business Critical (BC)** | Local SSD, built-in Always On AG (3–4 replicas) | Highest; built-in read-scale replica; zone-redundant option | 4 TB | Low-latency IO, high availability, in-memory OLTP, free readable secondary |
| **Hyperscale** | Distributed: page servers + log service + RBPEX cache | HA replicas + named replicas; zone-redundant option | **100 TB** | Very large DBs, fast restore, read scale-out, rapid scale up/down |

**DTU↔vCore rough mapping:** ~100 DTU Standard ≈ 1 GP vCore; Premium DTUs map toward Business Critical. Treat this as a starting point only; validate with `sys.dm_db_resource_stats`.

---

## 2. Serverless Compute

Available in **General Purpose** and **Hyperscale**. Instead of a fixed vCore count you set a **min and max vCore range**; compute auto-scales within it based on load and you are billed **per second** for vCores used (storage billed separately).

- **Auto-pause**: after a configurable idle delay, the database pauses and you pay **only for storage**. The next connection resumes it (a short warm-up latency on the first query). Disable auto-pause for latency-sensitive apps.
- Memory and cache are reclaimed when scaling down/pausing, so cold-start performance dips.
- **Best for:** intermittent, unpredictable, or dev/test workloads. **Worst for:** steady 24×7 OLTP — a provisioned tier is cheaper there.

---

## 3. Elastic Pools

An **elastic pool** is a shared pool of vCores/DTUs that a set of databases draws from. Each DB can burst up to a per-DB cap, but the *pool* has an aggregate budget.

- **Use when:** you have many databases (classic SaaS multi-tenant — one DB per tenant) that peak at **different times**, so their usage averages out. The pool is sized to the aggregate, not the sum of peaks → big savings.
- **Don't use when:** databases peak **simultaneously** (no smoothing benefit) or you have only a few large DBs.
- Pools exist in both DTU and vCore models, and in GP/BC tiers. Hyperscale does not participate in pools.

---

## 4. Hyperscale Architecture

Hyperscale is a re-architected storage engine, not just a bigger tier. Compute is separated from a multi-tier distributed storage system:

- **Compute nodes** — the primary (read-write) and optional secondary replicas. Each has a local **RBPEX** (Resilient Buffer Pool Extension) SSD cache.
- **Page servers** — own slices of the database (each covers up to ~1 TB) and serve pages to compute nodes on demand. Scaling storage = adding page servers transparently.
- **Log service** — a durable, fan-out log landing zone; the primary writes log once, the log service forwards it to page servers and all secondary replicas. This decoupled log is why Hyperscale commits stay fast at scale.
- **Azure storage** — long-term backup of data files and log, enabling **near-instant backups** (snapshot-based, no size-of-data copy) and **fast restore** (constant-time regardless of DB size).

Capabilities:
- Up to **100 TB**; grow without pre-provisioning storage.
- **Rapid scale** of compute up/down in minutes (it's a metadata/cache operation, not a data copy).
- **Read scale-out** via **HA replicas** (for availability + reads) and **named replicas** (independent endpoints/SLOs for read-only workloads, e.g. reporting, isolated from the primary's compute).
- Zone-redundant configuration available.

Limits/caveats: some features differ (e.g. historically no In-Memory OLTP, certain shrink/restore behaviors); reverting *off* Hyperscale requires export/import, not a tier change.

---

## 5. Built-in HA, Zone Redundancy & Read Scale-Out

- **Built-in local HA** is automatic on every tier. GP keeps one compute node against remote-stored data (fast failover by reattaching storage). BC/Premium run a **local Always On AG** with 3–4 synchronous replicas on local SSD.
- **Zone redundancy** spreads replicas across availability zones in the region for a higher SLA (up to 99.995%). Available on Premium/BC, Hyperscale, and GP (where supported). It protects against a datacenter/zone failure within the region.
- **Read scale-out** (BC/Premium and Hyperscale): a built-in read-only replica is available at no extra compute charge on BC. Route reads to it with `ApplicationIntent=ReadOnly` in the connection string. Offloads reporting from the primary.

---

## 6. Active Geo-Replication vs Auto-Failover Groups

Both give cross-region DR. They differ in granularity and how clients reconnect.

### Active geo-replication
- **Per-database** asynchronous replication to up to **4 readable secondaries** in any region.
- Failover is **manual** and **per database**. After failover, the old primary becomes a secondary (no data loss only with planned failover; unplanned can lose the async tail).
- Clients must connect to the secondary's **own server name** — there is no automatic endpoint redirection. The app must handle the new connection target (or you front it with a failover group).
- Good for: read scale across regions, fine-grained DR, multiple geo-distributed read copies.

### Auto-failover groups
- A **group** of databases on a logical server replicated to a partner server in another region, with **automatic failover** (policy-driven) and a configurable grace period.
- Provides two **listener endpoints** that don't change on failover:
  - **read-write listener**: `<fog-name>.database.windows.net` — always points at the current primary.
  - **read-only listener**: `<fog-name>.secondary.database.windows.net` — points at the readable secondary.
- On failover, the listener DNS is repointed to the new primary, so the **connection string does not change** — the app reconnects to the same listener and lands on the new primary. This is the key operational advantage over raw geo-replication.
- Available for **both Azure SQL Database and Managed Instance**.
- Caveat: when adding new databases to the logical server after a failover group exists, they are *not* automatically added to the group — you must add each one (single-DB FOG) unless using the MI/all-databases model.

**Rule:** use a failover group when you want transparent client redirection and grouped failover; use raw geo-replication only for fine-grained per-DB control or extra read replicas.

---

## 7. Backups, PITR & Long-Term Retention

Backups are **automatic and managed by Microsoft** — you cannot run `BACKUP DATABASE` to a local path, and you don't manage the backup chain.

- **Full** backups weekly, **differential** every 12–24h, **transaction log** every 5–10 min, all stored in Azure storage (locally-, zone-, or geo-redundant per your setting).
- **Point-in-time restore (PITR):** restore to any second within the retention window (default 7 days, configurable **1–35 days**). Restore always creates a **new database** — you cannot overwrite in place.
- **Long-Term Retention (LTR):** keep weekly/monthly/yearly full backups for up to **10 years** for compliance.
- **Geo-restore:** restore from geo-replicated backups into another region (RPO depends on the last geo-replicated backup).
- There is no `COPY_ONLY` ad-hoc backup to disk and no `RESTORE` from your own .bak (use BACPAC for export instead). For an exportable copy, use **Export to BACPAC** (schema+data) — note it is *not* transactionally consistent unless the DB is read-only/quiesced.

---

## 8. Elastic Jobs — the SQL Agent Replacement

Azure SQL Database **has no SQL Server Agent**. The replacement is **Elastic Jobs** (a.k.a. Elastic Database Jobs):

- A separate **Job Agent** resource targets a **job database** (an Azure SQL DB that stores job metadata).
- Targets are defined as **target groups**: a server (all its DBs), an elastic pool, individual DBs, or even DBs across servers/pools — so one job can fan out T-SQL to many databases.
- Schedules + retry/idempotency are built in. Output can be captured to a table.
- Use it for index maintenance, stats updates, schema rollouts, and recurring T-SQL across a fleet.
- For non-T-SQL orchestration (PowerShell, file moves, cross-service workflows) use **Azure Automation** or **Logic Apps / Data Factory** instead — Elastic Jobs only runs T-SQL.

---

## 9. What's Missing & the Workarounds

| Box / instance feature | On Azure SQL DB | Workaround |
|---|---|---|
| SQL Server Agent | **No** | Elastic Jobs (T-SQL); Azure Automation/Logic Apps for the rest |
| `USE db` / cross-database queries | **No** (each DB is an island) | **Elastic Query** / external data sources + external tables; or refactor |
| Cross-DB transactions, three-part names | **No** | Consolidate into one DB, or use Elastic Query (read-only-ish) |
| Linked servers | **No** | External data sources (limited); app-tier joins |
| `master` you can write to | **Logical only** | Server-level logins managed via the logical `master`; no real system DB |
| `msdb`, `model`, instance objects | **No** | N/A — there is no instance |
| FILESTREAM / FileTable | **No** | Blob storage + app handling |
| Service Broker (cross-DB) | **No** | Azure Service Bus / queues |
| CLR | **No** | Refactor to T-SQL or app tier |
| Most server-scoped DMVs / `sp_configure` | **Limited** | Database-scoped configs (`ALTER DATABASE SCOPED CONFIGURATION`), `sys.dm_db_resource_stats` |
| `xp_cmdshell`, OS access, trace flags | **No** | N/A |
| Database mail, Resource Governor | **No** | Azure-native services |

**Elastic Query** specifics: it lets a database run read queries against **remote** Azure SQL databases via external tables (vertical partitioning) or shard sets (horizontal). It is **read-mostly**, has performance/feature limits, and is being de-emphasized in favor of refactoring — don't treat it as a drop-in for linked servers.

---

## 10. Connection & Authentication Model

- **Server-level vs contained users.** You can create logins in the logical `master` and map users, *or* create **contained database users** (recommended) that authenticate directly against the database — contained users make the DB portable across failover/geo-replication without login-SID mismatches.
- **Microsoft Entra ID (formerly Azure AD)** authentication is the recommended path (managed identities, groups, MFA). SQL authentication is also supported. Windows/Kerberos is **not** available (no domain join). See `sqlserver-security` for the auth deep dive.
- **Connection policy** governs the network path:
  - **Redirect** (default within Azure): client is redirected straight to the node hosting the DB (lower latency, fewer hops) — requires outbound ports 11000–11999 open.
  - **Proxy**: all traffic goes through the gateway on 1433 (higher latency, simpler firewalling) — used for connections from outside Azure or when only 1433 is allowed.
- **Firewall**: server-level and database-level firewall rules; **Private Link / private endpoints** for fully private access; "Allow Azure services" toggle for intra-Azure reach.

---

## 11. Sizing Guidance

1. Baseline the source with `sys.dm_db_resource_stats` (or DMA's SKU recommendation, fed by a perfmon capture).
2. Choose model: **vCore** unless you have a reason to stay on DTU.
3. Choose tier: GP for balanced cost; BC for low-latency IO + HA + a free read replica; Hyperscale for >4 TB, fast restore, or read scale-out.
4. Right-size compute to **P95** CPU, not peak; use **serverless** if utilization is bursty/intermittent.
5. Set **max size** with headroom; enable **zone redundancy** if the SLA requires it.
6. Validate post-deploy: re-check `sys.dm_db_resource_stats` for sustained >80% on any dimension and resize.

> See `references/cloud-migration.md` for choosing Azure SQL DB *vs* MI *vs* VM as the target, and `scripts/01-azure-sql-db-health.sql` for a ready-to-run resource/SLO health check.
