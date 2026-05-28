---
name: sqlserver-ha-clustering
description: "SQL Server high availability, clustering, and disaster recovery: Always On Availability Groups (synchronous/asynchronous, contained, distributed, basic, read-scale), Failover Cluster Instances (FCI) on Windows Server Failover Clustering (WSFC), database mirroring and mirroring endpoints, log shipping, replication, quorum and witnesses, listeners, automatic seeding, and failover procedures. WHEN: \"Always On\", \"availability group\", \"AG\", \"readable secondary\", \"FCI\", \"failover cluster\", \"WSFC\", \"quorum\", \"witness\", \"database mirroring\", \"mirroring endpoint\", \"CREATE ENDPOINT\", \"log shipping\", \"replication\", \"distributor\", \"listener\", \"automatic seeding\", \"failover\", \"high availability\", \"disaster recovery\", \"DR\", \"RPO\", \"RTO\"."
license: MIT
metadata:
  version: "0.2.0"
---

# SQL Server High Availability, Clustering & Disaster Recovery

You are the specialist for everything that keeps SQL Server running through failures and recovers it after disasters: Always On Availability Groups, Failover Cluster Instances on WSFC, database mirroring and the **mirroring endpoints** that underpin both mirroring and AGs, log shipping, replication, quorum/witness design, and failover execution. This covers SQL Server 2016 through 2025 on **Windows, Linux/Pacemaker, and containers/Kubernetes**.

Cloud-managed HA (Azure SQL DB/MI auto-failover groups, zone redundancy, RDS Multi-AZ) is **not** owned here — cross-reference **`sqlserver-cloud`**. This skill owns the box-product and self-managed HA/DR technologies.

## How to Approach a Request

1. **Separate HA from DR.** HA = local resilience against node/instance failure (seconds–minutes, usually automatic). DR = recovery at another site/region after a larger failure (minutes–hours, usually a deliberate decision). They use different — often layered — technologies. See `references/dr-planning.md`.
2. **Pin the numbers.** What is the **RPO** (tolerable data loss) and **RTO** (tolerable downtime)? These drive synchronous vs asynchronous, automatic vs manual failover, and whether one technology suffices or you layer several.
3. **Pin the platform and edition.** Windows WSFC vs Linux/Pacemaker (`CLUSTER_TYPE = EXTERNAL`) vs cluster-less (`CLUSTER_TYPE = NONE`, 2017+) vs Kubernetes. **Standard Edition** is sharply limited (Basic AG only: single DB, two replicas, no readable secondary, no backup on secondary). Confirm before recommending.
4. **Pick the technology** with the selection matrix below, then load the matching reference file.
5. **Give verifiable T-SQL.** DDL that changes topology (failover, force-failover, suspend) must be deliberate — provide it, but flag the consequences. The `scripts/` here are **read-only diagnostics only**; failover/DDL appears only as commented templates.
6. **Point monitoring at `sqlserver-monitoring`** for alerting/waits, but use the AG/cluster DMVs here for HA-specific health.

## HA/DR Technology Selection Matrix

| Technology | Protects against | Storage | Granularity | Automatic failover | Readable secondary | Data-loss profile | Min edition |
|---|---|---|---|---|---|---|---|
| **FCI** (Failover Cluster Instance) | Instance/node/OS failure | **Shared** (SAN/S2D/SMB) | **Whole instance** | Yes (WSFC) | No (one active node) | Zero (same storage) | Standard (2 nodes) |
| **Always On AG** (sync) | DB/instance/node failure | **Non-shared** (own copy/replica) | Group of databases | Yes (sync + auto) | Yes (Enterprise) | Zero RPO when SYNCHRONIZED | Enterprise (Basic AG on Standard) |
| **Always On AG** (async) | Site/region failure (DR) | Non-shared | Group of databases | No (manual/forced) | Yes (Enterprise) | Non-zero (lag = RPO) | Enterprise |
| **Database mirroring** (high safety) | DB failure | Non-shared | **Single database** | Yes (with witness) | No (snapshot only) | Zero (sync) | Standard (sync); Async = EE |
| **Database mirroring** (high perf) | DB failure (DR) | Non-shared | Single database | No (manual/force) | No | Non-zero | Enterprise |
| **Log shipping** | DB failure / cheap DR | Non-shared | Single database | No | Yes (standby, read-only) | = log backup interval | All (incl. Web/Standard) |
| **Transactional replication** | Selective data distribution | Non-shared | **Tables/articles** | No | Yes (subscriber, writable) | Near-real-time latency | Standard+ (P2P = EE) |

Key distinctions:
- **FCI protects the instance; AG protects databases.** FCI has *one* copy of the data on shared storage (no redundant data, fast failover, no readable secondary). AG keeps *N* independent copies (data redundancy + read scale, but you maintain each copy).
- **FCI + AG combine well**: an AG whose replicas are themselves FCIs gives instance-level HA per site plus cross-site DR. (An AG replica that is an FCI cannot use *automatic* failover for that replica.)
- **Mirroring is deprecated** (since 2012) but everywhere in the field — migrate to AGs. It and AGs share the same **database-mirroring endpoint** transport.
- **Replication is data movement, not HA** — choose it when you need partial data, different schema/indexes on the target, or writable/bidirectional targets.

## Always On Availability Groups (deep)

Full architecture, T-SQL, and troubleshooting in `references/availability-groups.md`. The essentials:

- **Topology**: A WSFC (Windows) or Pacemaker (Linux, `CLUSTER_TYPE = EXTERNAL`) or no cluster at all (`CLUSTER_TYPE = NONE`, read-scale, 2017+) hosts an AG of up to **9 replicas** (1 primary + up to 8 secondaries, 2016+). Three distinct caps apply: **synchronous-commit** replicas — up to **3** on 2016/2017, raised to **5** (1 primary + 4 sync secondaries) on **2019+**; **automatic-failover targets** — up to **3** (1 primary + 2 sync secondaries) on 2016+, raised from 2 in 2012/2014. Each replica is a standalone instance (or an FCI) with its own copy of the availability databases. A **listener** (VNN + IP) provides a single connection point with read-only routing.
- **Availability mode**: `SYNCHRONOUS_COMMIT` (primary waits for the secondary to harden the log → zero data loss, latency cost) vs `ASYNCHRONOUS_COMMIT` (fire-and-forget → RPO = current lag, for WAN/DR). `session_timeout` (default 10s) controls when an unresponsive replica is declared disconnected.
- **Failover mode**: `AUTOMATIC` (requires sync-commit + the secondary SYNCHRONIZED) or `MANUAL`. `required_synchronized_secondaries_to_commit` (2017+) makes commits wait for *N* sync secondaries to be available, trading availability for guaranteed durability.
- **Seeding**: `AUTOMATIC` (direct stream over the endpoint — no manual backup/restore, 2016+) or manual backup/restore (`seeding_mode = MANUAL`). Automatic seeding needs matching paths and `GRANT CREATE ANY DATABASE` on the secondary.
- **Readable secondaries** (Enterprise): offload reads via read-only routing. Reads silently run under **snapshot isolation** (row versioning remapped), so a long secondary query grows the **tempdb version store** on that replica and can delay redo/ghost cleanup. Set `automated_backup_preference` to offload backups (use `COPY_ONLY` full backups; only log backups are fully supported on secondaries).
- **Flavors**: **Basic AG** (Standard, 2016+ — single DB, 2 replicas, no readable secondary), **Read-scale AG** (`CLUSTER_TYPE = NONE`, no WSFC, no automatic failover, 2017+), **Distributed AG** (AG-of-AGs spanning clusters/regions/OSes, 2016+), **Contained AG** (2022+ — replicates its own `master`/`msdb`, so logins/jobs/agents travel with the AG).

## FCI / WSFC + Quorum

Full detail in `references/failover-clustering.md`.

- An **FCI** is a single SQL Server instance installed across multiple WSFC nodes sharing storage; only one node owns it at a time, presented via a **virtual network name (VNN)**. Failover moves the instance (and its single data copy) to another node — clients reconnect to the same VNN. No readable secondary, because there is only one running instance.
- **Quorum** is how WSFC decides it still has a legitimate majority and avoids split-brain. Models: **Node Majority**, **Node & Disk Majority**, **Node & File Share Majority**, **Disk Only** (legacy, avoid), and **Cloud Witness** (Azure blob, 2016+). Modern WSFC uses **dynamic quorum** + **dynamic witness** and adjusts **node votes** automatically — always configure a witness so the cluster can break ties.
- **Multi-subnet FCI/AG**: the VNN/listener registers an IP per subnet. Set `RegisterAllProvidersIP = 1` and a low `HostRecordTTL` (e.g., 300s) and use `MultiSubnetFailover=True` in connection strings so clients fail over fast.
- **On Linux**, "FCI" in the Windows shared-storage sense does not exist; HA is delivered by **Pacemaker** managing AGs (or shared-storage FCI via Pacemaker resource agents with cluster-managed storage). See the Linux notes in both references.

## Database Mirroring & ENDPOINTS (key topic)

Full detail in `references/mirroring-endpoints.md`. This is a headline topic because the **database-mirroring endpoint is the data transport for BOTH database mirroring AND Always On AGs.**

- **Database mirroring** (deprecated since 2012, still common): a **principal** and a **mirror** per database, optionally a **witness** for automatic failover. Modes: **High Safety synchronous + witness** (automatic failover), **High Safety without witness** (manual failover), **High Performance asynchronous** (Enterprise, DR). Migrate survivors to AGs.
- **The endpoint** is created once per instance and reused by every mirroring session and every AG on that instance:
  ```sql
  CREATE ENDPOINT [Hadr_endpoint]
      STATE = STARTED
      AS TCP (LISTENER_PORT = 5022)
      FOR DATABASE_MIRRORING (
          ROLE = ALL,                              -- ALL | PARTNER | WITNESS
          AUTHENTICATION = WINDOWS NEGOTIATE,      -- or CERTIFICATE <cert>
          ENCRYPTION = REQUIRED ALGORITHM AES);
  GRANT CONNECT ON ENDPOINT::[Hadr_endpoint] TO [DOMAIN\sqlsvc];
  ```
- **Authentication**: **Windows (Kerberos/NTLM/NEGOTIATE)** when all replicas share a domain; **CERTIFICATE-based** when they are in different domains/workgroups or on **Linux** — create a master key + certificate on each replica, exchange the public-key certs, create a login mapped to the partner's certificate, and `GRANT CONNECT ON ENDPOINT` to it. The reference walks this end to end.
- **Port 5022** must be open in the firewall between replicas. Troubleshoot connectivity with `sys.endpoints`, `sys.database_mirroring_endpoints`, `sys.dm_tcp_listener_states`, endpoint state, and the classic **error 1418** (endpoint unreachable/encryption mismatch). Other endpoint types exist (`SERVICE_BROKER`, `TSQL`, `SOAP`-legacy), but DATABASE_MIRRORING is the HA one.

## Log Shipping

Full detail in `references/log-shipping-and-replication.md`. A primary backs up its log on a schedule; a **copy** job moves it to one or more secondaries; a **restore** job applies it (in `NORECOVERY` for warm-standby DR, or `STANDBY` for read-only-between-restores reporting). An optional **monitor** server tracks latency and raises alerts when backup/copy/restore fall behind thresholds. Cheap, simple, version-tolerant DR with RPO = the backup interval; failover is manual. State lives in `msdb.dbo.log_shipping_*`.

## Replication (overview)

Full detail in `references/log-shipping-and-replication.md`. **Publisher → Distributor → Subscriber** with agents (Snapshot, Log Reader, Distribution, Merge). Types: **Snapshot** (periodic full copy), **Transactional** (low-latency, one-way), **Peer-to-Peer** (Enterprise, multi-master), **Merge** (bidirectional with conflict resolution, occasionally-connected). It distributes *selected data* — use it for read scale-out, reporting copies, or heterogeneous targets, not as a primary HA mechanism.

## Failover Procedures

Detailed runbook in `references/dr-planning.md`. Three shapes:

- **Planned (manual) failover** — both sync replicas healthy; no data loss. AG: `ALTER AVAILABILITY GROUP [MyAG] FAILOVER;` (run on the *target* secondary; `[CONFIG CHANGE]` role change).
- **Unplanned automatic failover** — sync-commit + automatic mode + SYNCHRONIZED; WSFC/Pacemaker moves the role. Validate afterward.
- **Forced failover with possible data loss** — async or unsynchronized replica; **explicitly accepts data loss**. This is a **runbook TEMPLATE, not runnable SQL** — see the gated, pre-flight-checklisted version in `references/dr-planning.md` §5:
  ```sql
  -- [DATA-LOSS RISK] Forced failover CAN LOSE COMMITTED TRANSACTIONS. Last resort. Template only.
  -- PRE-FLIGHT (mandatory): verify the surviving replica's role/state; compare last_hardened_lsn
  --   across replicas; obtain documented business approval for data loss; confirm current verified
  --   backups; freeze/redirect the application; name the reconciliation/rollback owner.
  -- ALTER AVAILABILITY GROUP [CONFIRM_AG_NAME] FORCE_FAILOVER_ALLOW_DATA_LOSS;
  ```
  After a forced failover, the old primary (and other secondaries) must be **resumed** or **reseeded** to rejoin, and you must reconcile lost data. Full runbook in `references/dr-planning.md`.

Always: **detect → decide (consult RPO/RTO) → fail over → validate (app connectivity, sync state) → fail back when safe.**

## Monitoring Pointers

- HA-specific health: use the scripts here (`scripts/01`–`07`) and the AG/cluster/mirroring/endpoint DMVs.
- General alerting, waits (`HADR_SYNC_COMMIT`, `PARALLEL_REDO_*`, `DBMIRROR_*`), Query Store, and Extended Events live in **`sqlserver-monitoring`** — wire AG lag and sync-health alerts there.
- Backups that feed log shipping / AG-secondary backups are an **`sqlserver-operations`** concern.
- **Community tools** (read-only diagnostics, documented in `sqlserver-monitoring`): the **First Responder Kit** `sp_BlitzBackups` estimates RPO/RTO from `msdb` backup history — a useful cross-check against your AG/log-shipping RPO targets. See `sqlserver-monitoring` for install/usage and the broader sp_Blitz* / Erik Darling PerformanceMonitor coverage.

## Common Pitfalls

1. **No witness / bad quorum.** An even node count with no witness can lose quorum and take the whole cluster down. Always configure a witness (Cloud Witness is cheap and removes the file-share/disk dependency).
2. **`required_synchronized_secondaries_to_commit` set too high.** If you require more sync secondaries than you can keep healthy, the primary blocks commits when one goes down. Match it to your real replica count and durability needs.
3. **Reads on a secondary balloon tempdb.** Readable-secondary queries run under snapshot isolation; long queries grow the version store and stall redo. Watch tempdb and redo queue.
4. **Endpoint encryption/auth mismatch → error 1418.** All replicas must agree on encryption algorithm and the service accounts/certs must have `CONNECT` on each other's endpoints. Port 5022 must be open.
5. **Treating an async replica as zero-RPO.** Async = data loss equal to current lag. Don't promise zero RPO on an async DR replica.
6. **Forgetting `master`/`msdb` objects.** Pre-2022 (non-contained) AGs do **not** replicate logins, SQL Agent jobs, linked servers, or credentials — script them to every replica. Contained AG (2022+) fixes this.
7. **Single-subnet assumptions in multi-subnet topologies.** Without `RegisterAllProvidersIP` + low TTL + `MultiSubnetFailover=True`, clients can hang on stale IPs after failover.
8. **Mirroring left in production.** It is deprecated; plan migration to AGs (the endpoint and concepts carry over).
9. **Backups only on primary OR only on secondary, misconfigured.** Set `automated_backup_preference` deliberately; remember only **log** backups and **COPY_ONLY full** backups are supported on secondaries.

## Reference Files

- `references/availability-groups.md` — AG architecture (WSFC / NONE / EXTERNAL), modes, failover, seeding, readable secondaries & routing, backup preference, Basic/Read-scale/Distributed/Contained flavors, full CREATE T-SQL, sync-lag troubleshooting, Linux & Kubernetes.
- `references/failover-clustering.md` — WSFC fundamentals, all quorum models + dynamic quorum/witness & votes, FCI architecture, FCI vs AG, multi-subnet FCI/RegisterAllProvidersIP, FCI+AG topologies, Linux note, install overview.
- `references/mirroring-endpoints.md` — **headline**: (A) database mirroring modes/roles/setup/migration; (B) database-mirroring **ENDPOINTS** in depth — `CREATE ENDPOINT … FOR DATABASE_MIRRORING`, Windows vs certificate auth (step-by-step cross-domain/Linux), permissions, firewall, troubleshooting (1418).
- `references/log-shipping-and-replication.md` — log shipping (jobs, standby vs norecovery, thresholds, `msdb` tables); replication (topology, agents, Snapshot/Transactional/P2P/Merge, when to use each, latency monitoring, replication vs AG).
- `references/dr-planning.md` — RPO/RTO, HA-vs-DR, requirements→technology decision matrix and layering, failover runbook template, forced failover consequences, DR testing cadence, multi-site/cross-region, cloud DR pointer to `sqlserver-cloud`.

## Scripts

All are **READ-ONLY** diagnostics with a standard header, `SET NOCOUNT ON;`, and version/feature guards (e.g., `SERVERPROPERTY('IsHadrEnabled')`, column-existence checks for 2022-only columns). Failover/DDL appears only as commented templates.

- `scripts/01-ag-health.sql` — comprehensive AG health: config (+ contained/distributed, version-guarded), replica & database-replica state, send/redo queues & estimated lag, listener, automatic seeding progress, AG perf counters.
- `scripts/02-ag-failover-readiness.sql` — per-AG readiness: synchronization_health, all sync-commit replicas SYNCHRONIZED?, `required_synchronized_secondaries_to_commit` vs healthy count, suspended DBs & reason, quorum votes, last_commit_time skew, automatic-failover-target validity.
- `scripts/03-mirroring-health.sql` — `sys.database_mirroring` state/role/safety/witness/partner, witness state, mirroring send/redo via perf counters; notes deprecation.
- `scripts/04-endpoints.sql` — `sys.endpoints` + `sys.database_mirroring_endpoints` (type/state/role/encryption/auth/port), `CONNECT` grants on endpoints, `sys.dm_tcp_listener_states`, certificate-auth endpoints joined to `sys.certificates`.
- `scripts/05-cluster-health.sql` — `sys.dm_hadr_cluster`, `sys.dm_hadr_cluster_members` (votes/state), `sys.dm_hadr_cluster_networks`; guards IsHadrEnabled / IsClustered.
- `scripts/06-log-shipping-status.sql` — `msdb` log_shipping monitor tables for last backup/copy/restore, latency vs thresholds, alert status; guards if not configured.
- `scripts/07-replication-status.sql` — detect Publisher/Distributor, list publications/articles/subscriptions, undistributed-command/latency hints; guards gracefully if replication not installed.
