---
name: sqlserver-operations
description: "SQL Server day-to-day operations and core DBA tasks: backup and recovery strategy, restore testing, recovery models, point-in-time recovery, index and statistics maintenance, DBCC CHECKDB and corruption handling, SQL Agent jobs/alerts/Database Mail, patching and cumulative-update strategy, and space/capacity management. WHEN: \"backup\", \"restore\", \"recovery model\", \"point-in-time\", \"RPO\", \"RTO\", \"DBCC CHECKDB\", \"corruption\", \"maintenance plan\", \"Ola Hallengren\", \"index maintenance\", \"update statistics\", \"SQL Agent job\", \"alert\", \"Database Mail\", \"cumulative update\", \"patch\", \"disk space\", \"shrink\", \"VLF\"."
license: MIT
metadata:
  version: "0.1.0"
---

# SQL Server Operations

You are the operations expert for Microsoft SQL Server: the day-to-day DBA work that keeps databases recoverable, healthy, maintained, automated, patched, and within capacity. This skill covers the box product (2016–2025 on Windows/Linux/containers) **and** the managed offerings (Azure SQL Database, Azure SQL Managed Instance, SQL on Azure VM, AWS RDS). Always confirm version and platform before answering — feature availability and the operational surface differ sharply between them.

For performance diagnostics route to **sqlserver-monitoring**; for AG/FCI failover and rolling upgrades route to **sqlserver-ha-clustering**; for tempdb sizing and instance config route to **sqlserver-infrastructure**; for partitioning/archiving as a design technique route to **sqlserver-engineering**; for PaaS-specific behavior route to **sqlserver-cloud**; for backup encryption key management and TDE route to **sqlserver-security**.

## How to Approach an Operations Request

1. **Establish version, edition, and platform first.** `SELECT @@VERSION;`, `SELECT SERVERPROPERTY('Edition'), SERVERPROPERTY('EngineEdition');` (EngineEdition 5 = Azure SQL DB, 8 = Managed Instance, 3 = Enterprise/box). These gate nearly everything: online rebuild, resumable operations, S3 backup, the very existence of SQL Agent, and which DMVs/columns exist.
2. **Anchor on recoverability.** The single most important operational question is "can we restore to the point the business requires?" Confirm the recovery model, the backup chain, and that restores are *tested*. Everything else is secondary to this.
3. **Quantify RPO and RTO.** Translate the business requirement into a concrete backup schedule (log backup interval = RPO ceiling) and a restore plan (full → diff → log sequence = RTO driver). Do the math; do not hand-wave.
4. **Assess, then act.** Diagnostics (the `scripts/` here) are read-only. Maintenance and remediation (rebuilds, REPAIR, shrinks, patching) are *changes* — present them as reviewed, scheduled actions with rollback, never blind one-liners.
5. **Respect platform constraints.** Azure SQL DB has no SQL Agent and backups are automatic/managed — you cannot run `BACKUP DATABASE`. Managed Instance has Agent but no Database Mail to arbitrary SMTP in the same way, and limited trace flags. RDS has no `sa`, restricted sysadmin, and uses stored-procedure wrappers (`rdsadmin`) for many tasks. Never prescribe box-product T-SQL on PaaS without checking.
6. **Automate idempotently and alert on failure.** A maintenance job that silently fails is worse than none. Every scheduled job needs failure notification wired to an operator.

## Backup and Recovery Strategy

Recoverability is the DBA's first duty. Read `references/backup-recovery.md` for the full treatment; the essentials:

### Recovery models

| Model | Log backups | Point-in-time | Minimally-logged ops | Typical use |
|---|---|---|---|---|
| **Simple** | Not possible | No | Yes | Dev/test, read-only/regenerable data, some data warehouses |
| **Full** | Required | Yes (to any time covered by the chain) | No | Production OLTP, anything needing PITR or compliance |
| **Bulk-logged** | Required | Limited (not into a bulk-op window) | Yes | Temporary, only during large bulk loads/index builds |

The log of a **Full**-recovery database grows until you back it up. The #1 "log is full" incident is a Full database whose log has never been backed up. Either take log backups or, if PITR is genuinely not required, switch to Simple — never set `AUTO_SHRINK` or repeatedly shrink the log to cope.

### Backup types

| Type | What it captures | Resets diff base | Use |
|---|---|---|---|
| **Full** | Entire DB + enough log to be consistent | Yes | Foundation of every chain |
| **Differential** | Extents changed since last full | No | Shrinks restore time between fulls |
| **Log** | Log records since last log backup | No | PITR + log truncation (Full/Bulk-logged only) |
| **Copy-only full** | Full snapshot that does **not** reset the diff base | No | Ad-hoc copy without disturbing the chain |
| **File / filegroup** | Individual files/filegroups | — | VLDBs, piecemeal restore |
| **Partial** | Read-write filegroups only | — | VLDBs with large read-only data |

### Modern backup options (use these by default on box)

```sql
-- Full backup: compression + integrity check, overwrite the target, progress
BACKUP DATABASE [MyDB] TO DISK = N'E:\Backups\MyDB_Full.bak'
WITH COMPRESSION, CHECKSUM, INIT, STATS = 10;

-- Differential
BACKUP DATABASE [MyDB] TO DISK = N'E:\Backups\MyDB_Diff.bak'
WITH DIFFERENTIAL, COMPRESSION, CHECKSUM, INIT;

-- Transaction log (the RPO knob)
BACKUP LOG [MyDB] TO DISK = N'E:\Backups\MyDB_Log.trn'
WITH COMPRESSION, CHECKSUM, INIT;

-- Encrypted backup (2014+); the certificate/key itself must also be backed up
BACKUP DATABASE [MyDB] TO DISK = N'E:\Backups\MyDB_Enc.bak'
WITH COMPRESSION, CHECKSUM,
     ENCRYPTION (ALGORITHM = AES_256, SERVER CERTIFICATE = [BackupCert]);
```

- `CHECKSUM` validates pages on the way out and lets `RESTORE VERIFYONLY ... WITH CHECKSUM` re-validate. Always on.
- `COMPRESSION` is Standard+ (2016 SP1+); typically 3–4× smaller and *faster* because less I/O. Skip only when the data is already compressed (TDE/columnstore gain less).
- `BACKUP ... TO URL` writes to Azure Blob (2012 SP1+); `BACKUP ... TO URL` with an **S3-compatible** endpoint is **2022+**. See the reference.

### RPO / RTO math (the part people skip)

- **RPO** (max acceptable data loss) ≈ your log-backup interval, plus exposure if the last log backup's media is lost. A 15-minute log schedule means up to ~15 minutes of loss. Need 5? Back up the log every 5 (or use an AG/synchronous replica for near-zero — see **sqlserver-ha-clustering**).
- **RTO** (max acceptable downtime) is driven by restore time: full restore + each diff + replaying log backups + recovery + tail-log. Differentials exist to *cut RTO*. If a full + 47 log backups takes 3 hours and your RTO is 1, add a differential schedule.

### Restore sequence and point-in-time

```sql
-- 1) Capture the tail of the log first if the DB is still attached and online enough
--    (preserves the most recent transactions before you overwrite)
BACKUP LOG [MyDB] TO DISK = N'E:\Backups\MyDB_Tail.trn'
WITH NORECOVERY, NO_TRUNCATE;   -- NO_TRUNCATE for a damaged/offline DB

-- 2) Restore the most recent full, leaving the DB ready for more
RESTORE DATABASE [MyDB] FROM DISK = N'E:\Backups\MyDB_Full.bak'
WITH NORECOVERY, REPLACE;

-- 3) Restore the latest differential (optional, but speeds things up)
RESTORE DATABASE [MyDB] FROM DISK = N'E:\Backups\MyDB_Diff.bak'
WITH NORECOVERY;

-- 4) Roll forward log backups in order, stopping at the desired point
RESTORE LOG [MyDB] FROM DISK = N'E:\Backups\MyDB_Log_1.trn' WITH NORECOVERY;
RESTORE LOG [MyDB] FROM DISK = N'E:\Backups\MyDB_Log_2.trn'
WITH STOPAT = N'2026-05-27T14:32:00', NORECOVERY;

-- 5) Finally bring the database online
RESTORE DATABASE [MyDB] WITH RECOVERY;
```

**Test restores or you have no backups.** An untested backup is a hope, not a strategy. Schedule periodic test restores to a scratch instance and run `DBCC CHECKDB` on the result.

### Cloud / platform differences

- **Azure SQL Database / Managed Instance**: backups are **automatic and managed by Microsoft** (full ~weekly, diff ~12–24h, log every 5–10 min). You restore via portal/PowerShell/T-SQL point-in-time within the configured PITR retention (1–35 days) or **Long-Term Retention (LTR)** up to 10 years. You cannot issue `BACKUP DATABASE` to take the operational backup (MI allows `COPY_ONLY` backups to URL for export/migration).
- **SQL on Azure VM / AWS RDS box-style**: VM is the box product — you own backups (or use Azure Backup / the SQL IaaS extension automated backup). **RDS** takes automated snapshots and supports native `.bak` backup/restore to S3 via `rdsadmin.dbo.rds_backup_database` / `rds_restore_database` — you do **not** run `BACKUP DATABASE` directly.

## Maintenance: Index, Statistics, and Integrity

Read `references/maintenance.md` for depth. The operating thresholds:

### Index fragmentation

| avg_fragmentation_in_percent | Action | Statement |
|---|---|---|
| < 10% | None | — |
| 10–30% | Reorganize (online, resumable, incremental) | `ALTER INDEX … REORGANIZE` |
| > 30% | Rebuild | `ALTER INDEX … REBUILD` |

Only consider indexes above ~1,000–8,000 pages; fragmentation on tiny indexes is noise. **ONLINE rebuild** is Enterprise on 2016–2019, and available in **Standard from 2019+** for some operations and broadly **2022+**; verify per build. **RESUMABLE** rebuild is **2017+** and resumable *create* is **2019+** — invaluable for big indexes in short maintenance windows.

```sql
-- Online, resumable rebuild with a fill factor (Enterprise / 2019+/2022+ per edition)
ALTER INDEX [IX_Orders_CustomerId] ON dbo.Orders
REBUILD WITH (ONLINE = ON, RESUMABLE = ON, FILLFACTOR = 90, MAX_DURATION = 60 MINUTES);
```

### Statistics

Stale statistics produce bad cardinality estimates and bad plans. Keep `AUTO_UPDATE_STATISTICS` on; enable `AUTO_UPDATE_STATISTICS_ASYNC` for OLTP to avoid stall-on-update. For large tables, schedule manual `UPDATE STATISTICS … WITH FULLSCAN` (or a high sample) during the maintenance window — auto-update samples lightly and can misestimate. Trace flag **2371** (lower auto-update threshold for big tables) is the *default* from 2016+; only set it manually on 2014 and earlier.

### Integrity: DBCC CHECKDB

`DBCC CHECKDB` is non-negotiable, ideally weekly. It validates allocation, table/index/system structures, and (with `DATA_PURITY`) column values.

```sql
DBCC CHECKDB ([MyDB]) WITH NO_INFOMSGS, ALL_ERRORMSGS, DATA_PURITY;
```

**Corruption decision tree** (full version in the reference):

1. **Do not panic and do not immediately run REPAIR.** Note the error, the page IDs, and run `DBCC CHECKDB` again to confirm.
2. **Check the hardware/IO subsystem** — corruption is almost always storage. Look for OS errors 823/824/825 and `msdb.dbo.suspect_pages`.
3. **Restore from backup** — the correct fix. Use **page-level restore** for a handful of pages (Enterprise online, Standard offline) or a full restore + log roll-forward to recover with zero data loss.
4. **`REPAIR_ALLOW_DATA_LOSS` is the last resort** — it deallocates corrupt pages, *destroying the data on them*, and requires `SINGLE_USER`. Only when there is no good backup. Take a backup of the corrupt DB first, then repair, then `CHECKDB` again, then reconcile lost rows.

**Ola Hallengren's Maintenance Solution** is the industry standard for box/VM/MI: intelligent `IndexOptimize` (fragmentation- and page-count-aware, reorg/rebuild thresholds, stats), `DatabaseIntegrityCheck`, and `DatabaseBackup`. Prefer it over the GUI Maintenance Plans, which rebuild everything indiscriminately.

## SQL Agent, Alerts, and Database Mail

Read `references/agent-jobs.md`. SQL Agent (jobs → steps → schedules, plus operators, alerts, proxies) is how box/VM/MI automate operations.

- **Express has no Agent.** **Managed Instance has Agent.** **Azure SQL Database has no Agent — use Elastic Jobs** (the elastic job agent + target groups) instead; the reference covers the mapping. **RDS** has Agent but with constraints.
- Wire **failure notification** on every job (notify an operator on failure), set retry counts/intervals on flaky steps, and own jobs with a low-privilege login, not a personal account.
- Configure **alerts** on severity **17–25** (resource, fatal) and specific message IDs like **823/824/825** (I/O), plus performance-condition and WMI alerts. Severity 19+ and 823/824/825 should always page someone.
- **Database Mail** is the notification transport (set up a profile/account → SMTP). Managed Instance supports Database Mail; Azure SQL DB does not (use Logic Apps / Action Groups). Send a test with `sp_send_dbmail`.

## Patching and Cumulative-Update Strategy

(Detail lives in `references/capacity-management.md` alongside servicing.)

- SQL Server moved to a **CU-only servicing model** (no more Service Packs since 2017). CUs ship roughly monthly early in a release, then every two months; they are **cumulative** and now considered as tested as the old SPs — stay reasonably current rather than waiting for an "SP."
- **Always**: read the CU KB for breaking changes/fixes, snapshot/back up first, test in non-prod, and have a rollback plan (CUs are uninstallable; have the prior installer staged).
- **HA rolling upgrade**: patch secondaries first, fail over, then patch the former primary to minimize downtime — see **sqlserver-ha-clustering** for the AG/FCI rolling-upgrade sequence.
- **PaaS**: Azure SQL DB/MI are patched by Microsoft (you only control maintenance windows). **RDS** patching is via engine version upgrades you schedule. **Azure VM** can use the SQL IaaS extension's automated patching.

## Capacity and Space Management

Read `references/capacity-management.md`.

- **Autogrowth**: never leave data files on percentage growth or a tiny 1 MB increment. Use a fixed, sensible MB size (e.g., 256 MB–1 GB depending on DB size), and pre-size to avoid growth during business hours.
- **Instant File Initialization (IFI)**: grant *Perform Volume Maintenance Tasks* to the SQL service account so data-file growth/restore skips zeroing (huge speed-up). Log files cannot use IFI — they are always zeroed.
- **VLFs**: too many virtual log files (from many small log growths) slow recovery and log operations. Grow the log in chunks (e.g., 8 GB at a time so each growth adds ~16 VLFs of reasonable size) and check the count.
- **Shrink is harmful**: `DBCC SHRINKFILE`/`SHRINKDATABASE` fragments indexes and the file just regrows. Acceptable only as a one-off after a large permanent data deletion — and rebuild affected indexes afterward. Never enable `AUTO_SHRINK`.
- **tempdb sizing** is config, not maintenance — see **sqlserver-infrastructure**. **Archiving/partitioning** to control growth is a design technique — see **sqlserver-engineering**.

## Common Pitfalls

1. **Full recovery model with no log backups** — the log grows forever. Take log backups or switch to Simple.
2. **Untested backups** — schedule periodic test restores + `CHECKDB` on the copy.
3. **`INIT` vs `NOINIT` confusion / appending forever** — `INIT` overwrites the media set; appending grows files unboundedly and complicates restore. Prefer one-file-per-backup naming.
4. **Rebuilding every index nightly** — wastes I/O and bloats log/backups. Use threshold-based maintenance (Ola).
5. **`REPAIR_ALLOW_DATA_LOSS` as a first move** — it destroys data. Restore from backup first.
6. **No failure alerting on jobs** — silent failures = surprise outages.
7. **Percentage autogrowth + no IFI** — stalls and VLF explosions.
8. **Treating PaaS like the box** — no `BACKUP DATABASE` on Azure SQL DB, no Agent there, no `sa` on RDS.
9. **Shrinking routinely** — index fragmentation and churn. Right-size instead.
10. **Forgetting to back up the encryption certificate/key** — an encrypted backup you cannot decrypt is useless. Back up the cert + private key off-box.

## Reference Files

- **`references/backup-recovery.md`** — recovery models in depth; all backup types; COMPRESSION/CHECKSUM/INIT/encryption; BACKUP TO URL (Azure Blob) and S3 (2022+); RPO/RTO math; restore sequences, STOPAT point-in-time, tail-log, page restore, piecemeal/online restore; VERIFYONLY; restore testing; 3-2-1 rule; backup chains and `log_reuse_wait_desc`; retention/LTR.
- **`references/maintenance.md`** — index reorg/rebuild thresholds, ONLINE/RESUMABLE/fill factor; statistics (auto vs manual, FULLSCAN, async, TF 2371); DBCC CHECKDB/CHECKTABLE/CHECKALLOC, NO_INFOMSGS, DATA_PURITY; corruption decision tree and `suspect_pages`; Ola Hallengren; maintenance windows.
- **`references/agent-jobs.md`** — Agent architecture; creating jobs in T-SQL; failure handling/retries; Database Mail; alerts (severity 17–25, performance, WMI); MSX/TSX; Express/MI/Azure SQL DB Elastic Jobs/RDS constraints.
- **`references/capacity-management.md`** — autogrowth, IFI, data/log file management, VLF management, shrink guidance, growth trending; patching/CU servicing model with rollback and AG rolling-upgrade pointer.

## Scripts (read-only diagnostics)

- **`scripts/01-backup-status.sql`** — last full/diff/log backup per DB, age vs recovery model, no-recent-backup flags, recovery-model audit, size & compression ratio.
- **`scripts/02-restore-history.sql`** — restore history (who/what/when) from `msdb` restore tables.
- **`scripts/03-backup-chain-health.sql`** — `log_reuse_wait_desc`, recovery model vs log-backup presence, broken-chain and LSN-continuity hints.
- **`scripts/04-agent-jobs-health.sql`** — job inventory, enabled/disabled, last outcome, failures, running/long-running jobs, schedules, sysadmin-owned jobs.
- **`scripts/05-index-fragmentation.sql`** — fragmentation by index (LIMITED scan), page-count filter, recommended action (none/reorg/rebuild) — assessment only.
- **`scripts/06-statistics-health.sql`** — stats last_updated, rows, rows_sampled, modification_counter, stale-stats flag.
- **`scripts/07-integrity-status.sql`** — last known good CHECKDB approach, `suspect_pages` report, safe alternative to intrusive DBINFO reads.
- **`scripts/08-database-space-usage.sql`** — per-file size/used/free, autogrowth, IFI note, VLF count, log space used.
