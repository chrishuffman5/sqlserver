# Log Shipping & Replication Reference

Two related-but-distinct technologies. **Log shipping** is a cheap, simple, version-tolerant warm-standby / DR mechanism for whole databases. **Replication** is a flexible *data-distribution* platform (selected tables, possibly bidirectional, possibly heterogeneous) — useful for read scale-out and reporting, but **not** primarily an HA mechanism. For AGs see `availability-groups.md`; for choosing between technologies see `dr-planning.md`.

---

# Part A — Log Shipping

## A1. What It Is

Log shipping automates: **back up** the transaction log on the **primary** → **copy** it to one or more **secondaries** → **restore** it on each secondary. It runs entirely on SQL Agent jobs and standard backup/restore, so it tolerates version and edition differences well and works on virtually all editions.

## A2. Roles & Jobs

| Component | Role |
|---|---|
| **Primary server/database** | The source. A **backup job** backs up its log on a schedule. |
| **Secondary server/database** | One or more targets. A **copy job** pulls log backups to the secondary; a **restore job** applies them. |
| **Monitor server** (optional) | A separate instance that records history/status and raises **backup/restore alerts** when thresholds are exceeded. Optional but recommended (don't host it on primary or secondary). |

Three SQL Agent jobs drive it: **Backup** (on primary), **Copy** and **Restore** (on each secondary), plus **Alert** jobs (on the monitor, or on primary/secondary if no monitor).

## A3. Secondary Database Recovery State

When restoring the log on the secondary you choose one of:

| State | Behavior | Use |
|---|---|---|
| **`NORECOVERY`** (Standby = No Recovery) | DB stays in restoring state, **not readable** | Pure warm-standby DR — fastest to bring online on failover |
| **`STANDBY`** (read-only) | DB is **read-only between restores**; restores must disconnect readers (or wait) | DR **plus** offload read-only reporting (with read interruptions during restore) |

`STANDBY` writes an undo file so uncommitted transactions can be rolled forward on the next restore; readers are kicked off (or the restore waits) when the next log is applied.

## A4. Latency, Thresholds & Alerts

- **Backup alert threshold** — alert if no log backup has occurred within N minutes.
- **Restore alert threshold** — alert if no log restore has occurred within N minutes (secondary falling behind).
- **RPO** ≈ the **backup interval** (data since the last shipped log can be lost on failover). **RTO** = time to copy/restore outstanding logs + recover.
- The lag between primary backup time and secondary last-restored time is your effective freshness.

## A5. State Tables (`msdb`)

Query these to report status (see `scripts/06-log-shipping-status.sql`):

| Table (`msdb.dbo.`) | Contents |
|---|---|
| `log_shipping_monitor_primary` | Per primary DB: last backup file/date, backup threshold, history |
| `log_shipping_monitor_secondary` | Per secondary DB: last copied/restored file & date, latency, thresholds |
| `log_shipping_monitor_history_detail` | Detailed history of backup/copy/restore actions |
| `log_shipping_monitor_alert` | Alert-job configuration |
| `log_shipping_primary_databases` / `log_shipping_secondary` / `log_shipping_secondary_databases` | Configuration |

If log shipping isn't configured these tables exist but are empty (or, on a clean instance, may not be populated) — guard with row-count checks.

## A6. Failover (manual)

1. **Tail-log backup — only if the primary is reachable.** If the primary instance is up and the **log file is intact**, back up the tail of the log `WITH NORECOVERY` and apply it on the secondary for zero loss (this leaves the old primary in the `RESTORING` state). If the **data file is lost** but the log is still readable, you cannot take a normal tail-log backup — use `WITH NO_TRUNCATE` (and, for a damaged log, `CONTINUE_AFTER_ERROR`) to capture whatever the log holds; these are best-effort and may still mean some loss. If the primary is gone entirely, skip this step and accept RPO = the last shipped log.
2. Apply any outstanding copied logs on the secondary.
3. **Recover** the secondary: `RESTORE DATABASE [DB] WITH RECOVERY;` → it becomes the new primary.
4. Repoint applications; reconfigure log shipping in the new direction (or re-establish to a fresh secondary).

Failover is **always manual** — log shipping has no automatic failover. It pairs well as a *cheap third DR copy* alongside an AG (e.g., AG for HA + an archive log-shipping copy with delayed restore for "oops" protection).

## A7. Use as Cheap DR

- Cross-version/edition tolerant; works where AGs/clustering are too heavy.
- Multiple secondaries (e.g., one near, one far).
- A **delayed restore** secondary (deliberately holding logs before applying) provides protection against logical corruption/accidental deletes propagating instantly — something synchronous HA cannot give you.

---

# Part B — Replication

## B1. Topology & Components

The **publish/subscribe** metaphor:

| Component | Role |
|---|---|
| **Publisher** | Source instance that makes data available (defines **publications** of **articles** = tables/views/procs). |
| **Distributor** | Holds the **distribution database** (the replication "queue" + metadata + history). Can be local (on the publisher) or **remote** (dedicated). |
| **Subscriber** | Destination instance that receives data via **subscriptions** (push from distributor, or pull). |

### Agents

| Agent | Role | Used by |
|---|---|---|
| **Snapshot Agent** | Generates the initial schema + bulk-copy snapshot | All types (initial sync) |
| **Log Reader Agent** | Reads committed changes from the publisher's transaction log into the distribution DB | Transactional, P2P |
| **Distribution Agent** | Applies snapshot/transactions to subscribers | Snapshot, Transactional, P2P |
| **Merge Agent** | Synchronizes changes both ways and resolves conflicts | Merge |

## B2. Replication Types — When to Choose

| Type | Direction | Latency | Conflict handling | Use when | Edition |
|---|---|---|---|---|---|
| **Snapshot** | One-way, periodic full copy | High (batch) | n/a (full overwrite) | Small/slow-changing data; periodic refresh | Standard+ |
| **Transactional** | One-way, continuous | Low (near real-time) | n/a (one writer) | Read scale-out / reporting copies; offload reads | Standard+ |
| **Peer-to-Peer (P2P)** | Multi-master | Low | App must avoid/handle conflicts | Geo-distributed read+write, scale-out | **Enterprise** |
| **Merge** | Bidirectional | Variable (sync events) | **Built-in conflict resolution** | Occasionally-connected clients, mobile/field, bidirectional | Standard+ |

Decision guidance:
- Need a **near-real-time read-only reporting copy** with possibly different indexes? → **Transactional**.
- Need **selected tables**, not the whole DB, on the target? → any replication type (AG/mirroring/log shipping are whole-DB).
- Need **writes at multiple sites**? → **P2P** (no conflict resolution — design to avoid conflicts) or **Merge** (handles conflicts).
- Just need a **periodic copy** of small data? → **Snapshot**.

## B3. Detecting & Monitoring

Detection (see `scripts/07-replication-status.sql`):
- `sys.databases.is_published`, `is_subscribed`, `is_merge_published`, `is_distributor`.
- `SELECT * FROM sys.dm_server_registry` / `EXEC sp_get_distributor` to find the distributor.
- Catalog views in the distribution DB and publisher: `MSpublications`, `MSarticles`, `MSsubscriptions`, `syspublications`, `sysarticles` (exist only when replication is configured — guard with `OBJECT_ID()` checks).

Latency & health:
- **Tracer tokens** — inject a marker at the publisher and measure publisher→distributor and distributor→subscriber latency (`sp_posttracertoken`, `MStracer_tokens`/`MStracer_history`, or Replication Monitor).
- `sys.dm_repl_traninfo`, `sys.dm_repl_articles`, `sys.dm_repl_schemas`, `sys.dm_repl_tranhash` for in-flight detail.
- **Undistributed commands** — commands in the distribution DB not yet delivered to a subscriber (`sp_replmonitorsubscriptionpendingcmds`); a growing backlog = the distribution/subscriber can't keep up.
- The **Replication Monitor** GUI and `sp_replcounters` summarize latency/throughput per publication.

## B4. Replication vs AG

| Dimension | Replication | Always On AG |
|---|---|---|
| Granularity | **Tables/articles** (subset) | Whole databases (group) |
| Target schema | Can differ (different indexes, even some schema) | Identical copy |
| Target writable? | Yes (subscriber writable; P2P/Merge multi-master) | Read-only secondaries only |
| Primary purpose | **Data distribution / read scale-out** | **HA / DR** |
| Automatic failover | No | Yes (sync + automatic) |
| Heterogeneous targets | Possible (limited, historically) | No |

Use **replication when you need partial data, a writable/differently-shaped target, or multi-master**; use **AGs when you need HA/DR with automatic failover and identical copies.** They are often combined: an AG for HA, with transactional replication off the (readable) secondary for reporting distribution. Note replication+AG integration requires care — the distribution database and the replication redirection to the AG listener must be configured so replication survives an AG failover.
