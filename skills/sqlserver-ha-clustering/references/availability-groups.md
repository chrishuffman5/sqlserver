# Always On Availability Groups Reference

Deep reference for Always On Availability Groups (AGs) on SQL Server 2016–2025 across Windows (WSFC), Linux (Pacemaker), cluster-less read-scale, and Kubernetes. For the database-mirroring **endpoint** that AGs use as their transport, see `mirroring-endpoints.md`. For quorum/WSFC fundamentals, see `failover-clustering.md`. For RPO/RTO-driven technology choice, see `dr-planning.md`.

## 1. Architecture

An availability group is a set of user databases (the **availability databases**) that fail over together as a unit across a set of **availability replicas**.

### Cluster substrate (`CLUSTER_TYPE`)

The AG sits on top of a cluster manager that provides health detection and (optionally) automatic failover orchestration:

| `CLUSTER_TYPE` | Cluster manager | Automatic failover | Listener | Typical use | Version |
|---|---|---|---|---|---|
| `WSFC` (default on Windows) | Windows Server Failover Clustering | Yes | WSFC network name resource | Production HA on Windows | 2016+ |
| `EXTERNAL` | Pacemaker (Linux) | Yes (Pacemaker-driven) | Floating IP / read-only routing | Production HA on Linux | 2017+ |
| `NONE` | None (no cluster) | **No** (manual only) | No clustered listener (use a load balancer / read-only routing list) | Read-scale, migrations, dev | 2017+ |

The AG is created with `WITH (CLUSTER_TYPE = …)` in 2017+. On 2016 (Windows only) the AG always rides on WSFC.

### Replicas and roles

- Up to **9 replicas** total: **1 primary + up to 8 secondaries**.
- Up to **3 synchronous-commit** replicas may participate in automatic failover at once (one primary + two sync secondaries with automatic failover, historically; the engine supports up to 3 sync replicas).
- Each replica is a **standalone instance or an FCI**, each with its **own copy** of the availability databases (non-shared storage). An FCI replica cannot be an *automatic* failover target for the AG.
- Roles: **PRIMARY** (read-write, ships log) and **SECONDARY** (applies redo, optionally readable).

### Availability databases

- Must be in **FULL recovery** and have at least one full backup before joining.
- Replicated at the **database** level but managed as a group; system databases are **not** replicated (except in a **Contained AG**, 2022+ — see §6).
- `master`, `msdb` (logins, jobs, linked servers, credentials) are **not** carried by a traditional AG — you must script them to every replica. Contained AGs solve this.

### Listener

The **availability group listener** is a virtual network name (VNN) + one or more virtual IPs that clients connect to. It:
- Always points to the current **primary** for read-write connections.
- Routes **read-intent** connections to readable secondaries via the **read-only routing list/URL** (and **read-only load-balancing** across secondaries, 2016+, using a nested list).
- In multi-subnet topologies, has one IP per subnet (`RegisterAllProvidersIP`; clients use `MultiSubnetFailover=True`). See `failover-clustering.md`.

### Endpoints (transport)

Every replica needs a **database-mirroring-type endpoint** (default port **5022**) over which log blocks stream and seeding occurs. This is the *same* endpoint type database mirroring uses. Full coverage — including certificate-based auth for cross-domain/Linux — is in `mirroring-endpoints.md`.

## 2. Availability Modes & Session Timeout

| Mode | Commit behavior | Data loss | Latency | Use |
|---|---|---|---|---|
| `SYNCHRONOUS_COMMIT` | Primary waits for the secondary to **harden** the log record before acking the commit | Zero (while SYNCHRONIZED) | Adds round-trip latency | Local HA (LAN) |
| `ASYNCHRONOUS_COMMIT` | Primary commits without waiting for the secondary | = current lag | None on commit path | DR over WAN |

- `session_timeout` (default **10 seconds**): if a replica does not respond to pings within this window it is declared **DISCONNECTED**; for a sync replica this drops it out of the SYNCHRONIZED set (and can block automatic failover). Raise cautiously on flaky WANs.
- Sync transition states: `NOT SYNCHRONIZING → SYNCHRONIZING → SYNCHRONIZED` (sync mode) or stays `SYNCHRONIZING` (async mode — async never reaches SYNCHRONIZED).

## 3. Failover Modes & Durability Guarantees

| Failover mode | Requires | Behavior |
|---|---|---|
| `AUTOMATIC` | Sync-commit on both replicas **and** the secondary SYNCHRONIZED | Cluster promotes the secondary with no data loss |
| `MANUAL` | — | Planned (no loss, sync) or forced (`ALLOW_DATA_LOSS`, possible loss) |

### `required_synchronized_secondaries_to_commit` (2017+)

A group-level setting that says "a commit may only complete if at least *N* synchronous secondaries are available to harden it." Increasing it strengthens durability (more copies guaranteed) but reduces availability (if fewer than *N* sync secondaries are healthy, the primary **blocks commits**). Defaults:
- 0 historically; on 2017+ with newer configs the engine may auto-manage this for automatic failover scenarios.
- Set it explicitly to match your replica count: e.g., with 1 primary + 2 sync secondaries, `required_synchronized_secondaries_to_commit = 1` keeps a guaranteed second copy while tolerating one secondary down.

## 4. Seeding (Initial Data Synchronization)

`seeding_mode` per replica:

| `seeding_mode` | How the secondary gets the data |
|---|---|
| `AUTOMATIC` | Engine streams the database directly over the endpoint — no manual backup/restore (2016+). |
| `MANUAL` | DBA restores a full + log backup `WITH NORECOVERY`, then joins the database. |

**Automatic seeding requirements**:
- Database/log file **paths must exist** (matching layout) on the secondary, or use `db_file_path` mapping (Linux/cross-platform).
- The AG must have `GRANT CREATE ANY DATABASE` to the AG on the secondary:
  ```sql
  ALTER AVAILABILITY GROUP [ag] GRANT CREATE ANY DATABASE;   -- run on each secondary
  ```
- Watch progress with `sys.dm_hadr_automatic_seeding` and `sys.dm_hadr_physical_seeding_stats` (see `scripts/01-ag-health.sql`).
- Automatic seeding streams uncompressed by default; enable backup compression / trace flag 9567 to compress the seeding stream over slow links (test the CPU cost).

## 5. Readable Secondaries, Read-Only Routing & tempdb Impact

### Allowing reads

```sql
-- Per replica connection access
secondary_role (ALLOW_CONNECTIONS = { NO | READ_ONLY | ALL })
primary_role  (ALLOW_CONNECTIONS = { READ_WRITE | ALL })
```
- `READ_ONLY` requires `ApplicationIntent=ReadOnly` in the connection string; `ALL` allows any connection.
- Readable secondaries are **Enterprise-only** (Basic AG has none).

### Read-only routing

```sql
ALTER AVAILABILITY GROUP [ag]
MODIFY REPLICA ON N'NODE2'
WITH (PRIMARY_ROLE (READ_ONLY_ROUTING_LIST = (('NODE2','NODE3'), 'NODE4')));  -- load-balanced sub-list, then fallback
ALTER AVAILABILITY GROUP [ag]
MODIFY REPLICA ON N'NODE2'
WITH (SECONDARY_ROLE (READ_ONLY_ROUTING_URL = N'TCP://NODE2.contoso.com:1433'));
```
Clients connect to the **listener** with `ApplicationIntent=ReadOnly`; the primary redirects them per the routing list. Load-balancing across a sub-list (the inner parenthesized group) is 2016+.

### Snapshot isolation remapping & tempdb version store

Reads on a secondary are automatically run under **snapshot isolation** (row versioning) to avoid blocking redo, **regardless** of the isolation level the client requests — locking hints and higher isolation levels are silently remapped. Consequences:
- Long-running secondary queries hold old row versions → the **tempdb version store on that secondary grows** and **ghost/version cleanup and redo can stall** (watch `redo_queue_size`).
- A 14-byte versioning tag is added to rows as they are modified on the primary (one-time per-row overhead on first update after enabling readable secondaries).
- Monitor `sys.dm_tran_version_store_space_usage` and tempdb on each readable secondary.

## 6. Backups on Secondaries & `automated_backup_preference`

Offload backups from the primary:

```sql
ALTER AVAILABILITY GROUP [ag]
SET (AUTOMATED_BACKUP_PREFERENCE = SECONDARY);  -- PRIMARY | SECONDARY_ONLY | SECONDARY | NONE
```

Rules:
- On a secondary, **only log backups** (and `COPY_ONLY` **full** backups) are supported. Differential and non-copy-only full backups must run on the primary.
- Use `sys.fn_hadr_backup_is_preferred_replica(@dbname)` in your backup jobs (which run on **all** replicas) so each replica only backs up when it is the preferred one.
- `backup_priority` per replica picks which secondary backs up when preference = SECONDARY.

## 7. AG Flavors

### Basic Availability Group (Standard Edition, 2016+)
- Replaces deprecated database mirroring on Standard.
- **One database**, **two replicas** (1 primary + 1 secondary), **no readable secondary**, **no backup on secondary**, no listener read-only routing across multiple secondaries. Sync or async. Create with `WITH (BASIC)`.

### Read-Scale AG (`CLUSTER_TYPE = NONE`, 2017+)
- **No WSFC/Pacemaker** → **no automatic failover** and no clustered listener. Purely for **read scale-out** (or simple cross-platform replication). Failover is always manual (`FORCE_FAILOVER_ALLOW_DATA_LOSS` for role change). Works across Windows/Linux mixes.

### Distributed Availability Group (2016+)
- An **AG of AGs**: a primary AG (with its own primary replica) forwards to a secondary AG on another WSFC/cluster, possibly different region/OS. Used for cross-cluster DR, near-zero-downtime migrations (incl. Windows→Linux), and chaining. Each underlying AG retains its own listener; the distributed AG ties them together. Seeding and availability mode are configured at the distributed-AG level.

### Contained Availability Group (2022+)
- The AG contains its **own `master` and `msdb`** system databases, so **logins, SQL Agent jobs, linked servers, server-level objects** are replicated with the AG and survive failover automatically — solving the classic "forgot to script the logins/jobs" problem.
- Surfaced by `sys.availability_groups.is_contained = 1` (column exists **only on 2022+** — guard with a column-existence check before selecting it). Connect to the contained `master`/`msdb` via the listener with `Database=` set appropriately.

## 8. CREATE AVAILABILITY GROUP — T-SQL Examples

### Endpoint prerequisite (every replica)
See `mirroring-endpoints.md`. Briefly:
```sql
CREATE ENDPOINT [Hadr_endpoint] STATE = STARTED
    AS TCP (LISTENER_PORT = 5022)
    FOR DATABASE_MIRRORING (ROLE = ALL, ENCRYPTION = REQUIRED ALGORITHM AES);
GRANT CONNECT ON ENDPOINT::[Hadr_endpoint] TO [CONTOSO\sqlsvc];
```

### Standard two-replica synchronous AG with automatic failover + listener (Windows/WSFC)
```sql
CREATE AVAILABILITY GROUP [AG1]
WITH (AUTOMATED_BACKUP_PREFERENCE = SECONDARY,
      DB_FAILOVER = ON,
      REQUIRED_SYNCHRONIZED_SECONDARIES_TO_COMMIT = 0)
FOR DATABASE [Sales], [Inventory]
REPLICA ON
  N'NODE1' WITH (
      ENDPOINT_URL = N'TCP://node1.contoso.com:5022',
      AVAILABILITY_MODE = SYNCHRONOUS_COMMIT,
      FAILOVER_MODE = AUTOMATIC,
      SEEDING_MODE = AUTOMATIC,
      SECONDARY_ROLE (ALLOW_CONNECTIONS = READ_ONLY)),
  N'NODE2' WITH (
      ENDPOINT_URL = N'TCP://node2.contoso.com:5022',
      AVAILABILITY_MODE = SYNCHRONOUS_COMMIT,
      FAILOVER_MODE = AUTOMATIC,
      SEEDING_MODE = AUTOMATIC,
      SECONDARY_ROLE (ALLOW_CONNECTIONS = READ_ONLY));

-- On the SECONDARY:
ALTER AVAILABILITY GROUP [AG1] JOIN;
ALTER AVAILABILITY GROUP [AG1] GRANT CREATE ANY DATABASE;   -- for automatic seeding

-- Listener (on the primary):
ALTER AVAILABILITY GROUP [AG1]
ADD LISTENER N'AG1-LISTENER' (
    WITH IP ((N'10.0.0.50', N'255.255.255.0')),
    PORT = 1433);
```

### Read-scale AG with no cluster (2017+, cross-platform)
```sql
CREATE AVAILABILITY GROUP [ReadScaleAG]
WITH (CLUSTER_TYPE = NONE)
FOR DATABASE [Reporting]
REPLICA ON
  N'WINBOX'  WITH (ENDPOINT_URL=N'TCP://winbox:5022',
                   AVAILABILITY_MODE=SYNCHRONOUS_COMMIT, FAILOVER_MODE=MANUAL,
                   SEEDING_MODE=AUTOMATIC, SECONDARY_ROLE(ALLOW_CONNECTIONS=ALL)),
  N'LINUXBOX' WITH (ENDPOINT_URL=N'TCP://linuxbox:5022',
                   AVAILABILITY_MODE=SYNCHRONOUS_COMMIT, FAILOVER_MODE=MANUAL,
                   SEEDING_MODE=AUTOMATIC, SECONDARY_ROLE(ALLOW_CONNECTIONS=ALL));
-- Manual role change only (no automatic failover without a cluster):
-- ALTER AVAILABILITY GROUP [ReadScaleAG] FORCE_FAILOVER_ALLOW_DATA_LOSS;
```

### Linux AG (Pacemaker, `CLUSTER_TYPE = EXTERNAL`)
```sql
CREATE AVAILABILITY GROUP [AGLinux]
WITH (CLUSTER_TYPE = EXTERNAL)
FOR REPLICA ON
  N'node1' WITH (ENDPOINT_URL=N'TCP://node1:5022',
                 AVAILABILITY_MODE=SYNCHRONOUS_COMMIT, FAILOVER_MODE=EXTERNAL,
                 SEEDING_MODE=AUTOMATIC),
  N'node2' WITH (ENDPOINT_URL=N'TCP://node2:5022',
                 AVAILABILITY_MODE=SYNCHRONOUS_COMMIT, FAILOVER_MODE=EXTERNAL,
                 SEEDING_MODE=AUTOMATIC);
-- FAILOVER_MODE = EXTERNAL: Pacemaker, not SQL Server, drives failover.
-- Pacemaker resources (ocf:mssql:ag) + a virtual IP are configured at the OS level (pcs/crm).
```

### Basic AG (Standard, 2016+)
```sql
CREATE AVAILABILITY GROUP [BasicAG]
WITH (BASIC, DB_FAILOVER = ON, DTC_SUPPORT = NONE)
FOR DATABASE [App]
REPLICA ON
  N'NODE1' WITH (ENDPOINT_URL=N'TCP://node1:5022', AVAILABILITY_MODE=SYNCHRONOUS_COMMIT,
                 FAILOVER_MODE=AUTOMATIC, SEEDING_MODE=AUTOMATIC),
  N'NODE2' WITH (ENDPOINT_URL=N'TCP://node2:5022', AVAILABILITY_MODE=SYNCHRONOUS_COMMIT,
                 FAILOVER_MODE=AUTOMATIC, SEEDING_MODE=AUTOMATIC);
-- No readable secondary, single DB, exactly two replicas.
```

## 9. Sync-Lag Troubleshooting

The two queues tell you where lag lives:

| Metric (`sys.dm_hadr_database_replica_states`) | Meaning | If high… |
|---|---|---|
| `log_send_queue_size` (KB) | Log on the primary **not yet sent** to the secondary | Network/bandwidth between primary and secondary, or async by design |
| `log_send_rate` (KB/s) | Send throughput | Compare to generation rate |
| `redo_queue_size` (KB) | Log **received but not yet redone** on the secondary | Secondary I/O/CPU; a long readable-secondary query blocking redo; single-threaded redo (pre-parallel-redo) |
| `redo_rate` (KB/s) | Redo throughput on the secondary | — |

Estimated lag:
```sql
estimated_send_lag_sec = log_send_queue_size / NULLIF(log_send_rate,0)
estimated_redo_lag_sec = redo_queue_size      / NULLIF(redo_rate,0)
```
Also compare `last_commit_time` and `last_hardened_lsn` across replicas (skew = effective RPO for async). Use `scripts/01-ag-health.sql` and `scripts/02-ag-failover-readiness.sql`. Common causes:
- **High redo queue, low send queue** → secondary can't keep up applying (I/O/CPU, blocking reader). Parallel redo (2016+, on by default, up to limited threads) helps but a heavy readable workload can still stall it.
- **High send queue** → transport/network or an intentionally async DR replica.
- **Sudden divergence** → a suspended database (`is_suspended = 1`, check `suspend_reason_desc`).

## 10. AG on Linux (Pacemaker) — Operational Notes

- HA is delivered by **Pacemaker + Corosync**; SQL Server replicas use `CLUSTER_TYPE = EXTERNAL` and `FAILOVER_MODE = EXTERNAL`. SQL Server does **not** initiate failover — Pacemaker does, via the `ocf:mssql:ag` (and `ocf:mssql:fci` for shared-storage) resource agents.
- A **virtual IP** resource (and optionally a load balancer) provides the listener equivalent; read-only routing still works for read scale.
- Fencing (STONITH) is **required** for production to prevent split-brain. Set the cluster property and resource constraints carefully; an unfenced Pacemaker AG can dual-master.
- Endpoint auth is almost always **certificate-based** (no AD by default) — see `mirroring-endpoints.md`.
- `pacemaker` cluster type AGs honor `REQUIRED_SYNCHRONIZED_SECONDARIES_TO_COMMIT`; combine with sync mode for zero-RPO local HA on Linux.

## 11. AG on Kubernetes / Containers

- Use the **SQL Server Kubernetes operator** (or StatefulSets with persistent volumes). Each replica is a pod backed by a PVC; the AG is `CLUSTER_TYPE = NONE` or `EXTERNAL` depending on the operator.
- A Kubernetes **Service** (or the operator's listener resource) provides the stable endpoint; read-only routing maps to a read service.
- **Persistent volumes are mandatory** — pod rescheduling must not lose the data/log. Treat container AGs as advanced; validate failover, seeding, and storage durability before production.
- Cross-reference container platform specifics with `sqlserver-infrastructure`.

## 12. Quick DMV Map for AGs

| DMV / catalog view | Purpose |
|---|---|
| `sys.availability_groups` (+ `is_contained` 2022+, `is_distributed`) | AG config |
| `sys.availability_replicas` | Replica config (mode, failover, seeding, endpoint URL) |
| `sys.dm_hadr_availability_replica_states` | Replica role/health/connected state |
| `sys.dm_hadr_database_replica_states` | Per-DB sync state, queues, LSNs, commit times |
| `sys.availability_group_listeners` / `_listener_ip_addresses` | Listener + IPs |
| `sys.dm_hadr_automatic_seeding` / `sys.dm_hadr_physical_seeding_stats` | Seeding progress |
| `sys.dm_hadr_cluster` / `_cluster_members` / `_cluster_networks` | Underlying cluster |
| `sys.fn_hadr_backup_is_preferred_replica(db)` | Backup-on-secondary decision |
