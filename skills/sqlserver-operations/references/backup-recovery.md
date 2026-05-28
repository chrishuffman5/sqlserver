# Backup and Recovery Reference

Recoverability is the DBA's first responsibility. This reference covers recovery models, every backup type, modern backup options, the math behind RPO/RTO, restore sequences (including point-in-time and page restore), validation and testing, the backup chain, and retention. Box product 2016–2025 unless noted; cloud/platform differences are called out inline.

## Recovery Models

The recovery model controls how the transaction log is managed and what restore options exist.

| Model | Log backups | Point-in-time recovery | Minimally-logged ops | Log truncation trigger |
|---|---|---|---|---|
| **Simple** | Not allowed | No | Yes | Automatic at checkpoint |
| **Full** | Required | Yes (any time the chain covers) | No | Only by `BACKUP LOG` |
| **Bulk-logged** | Required | Limited (cannot stop inside a bulk-op interval) | Yes | Only by `BACKUP LOG` |

```sql
-- Inspect (read-only):
SELECT name, recovery_model_desc FROM sys.databases ORDER BY name;

-- [CONFIG CHANGE] Confirm DB via DB_NAME(); switching to/from SIMPLE BREAKS the log-backup chain
-- (take a fresh full afterward). Placeholder [MyDB]. Rollback: SET RECOVERY to the prior model.
ALTER DATABASE [MyDB] SET RECOVERY FULL;     -- or SIMPLE / BULK_LOGGED
```

**Simple** — checkpoints truncate the log automatically; no log backups are possible, so there is no point-in-time recovery and the most you can lose is everything since the last full/diff. Use for dev/test, scratch, and databases whose data can be regenerated. Some data warehouses run Simple and rely on full+diff plus the ability to reload.

**Full** — every change is fully logged and the log is *only* freed by a log backup. This is what enables PITR. The classic failure mode: a Full-recovery database whose log has never been backed up grows until the disk fills. Either take log backups on a schedule or switch the database to Simple if PITR is genuinely not needed. Never paper over it with repeated shrinks or `AUTO_SHRINK`.

**Bulk-logged** — like Full but bulk operations (BULK INSERT, `SELECT INTO`, index rebuilds, etc.) are minimally logged, so the log stays small during big loads. The cost: you cannot do point-in-time recovery *into* an interval that contains a minimally-logged operation, and the log backup that covers such an interval requires the data extents (can be large). Switch to Bulk-logged just for the bulk window, then back to Full and take a log backup.

> **Platform note:** On Azure SQL Database and Managed Instance the recovery model is **Full and fixed** (managed by the service) — you cannot change it. On RDS you can set it, but RDS requires Full for Multi-AZ.

## Backup Types

### Full backup

Captures the entire database plus enough of the log to make the restored copy transactionally consistent. It is the base of every restore chain and **resets the differential base**.

```sql
BACKUP DATABASE [MyDB] TO DISK = N'E:\Backups\MyDB_Full.bak'
WITH COMPRESSION, CHECKSUM, INIT, STATS = 10;
```

### Differential backup

Captures only the extents changed since the last full (tracked by the Differential Changed Map). Smaller and faster than a full; restoring full + latest diff replaces replaying many log backups, cutting RTO. A differential does **not** reset its own base — only a new full does. Diffs grow over time, so schedule periodic fulls.

```sql
BACKUP DATABASE [MyDB] TO DISK = N'E:\Backups\MyDB_Diff.bak'
WITH DIFFERENTIAL, COMPRESSION, CHECKSUM, INIT;
```

### Transaction log backup

Captures all log records since the previous log backup and truncates the inactive portion of the log. Only possible in Full/Bulk-logged. Log backups form a continuous chain by LSN; the interval is your RPO knob.

```sql
BACKUP LOG [MyDB] TO DISK = N'E:\Backups\MyDB_Log.trn'
WITH COMPRESSION, CHECKSUM, INIT;
```

### Copy-only backup

A full (or log) backup that does **not** disturb the chain — it does not reset the differential base (full) or truncate the log (log). Use for ad-hoc copies (e.g., refresh a dev environment) without breaking the scheduled diff/log sequence.

```sql
BACKUP DATABASE [MyDB] TO DISK = N'E:\Backups\MyDB_CopyOnly.bak'
WITH COPY_ONLY, COMPRESSION, CHECKSUM;
```

### File and filegroup backups

Back up individual files or filegroups instead of the whole database — essential for VLDBs where a full backup is impractical. Restore individual files combined with log backups to recover. Requires Full or Bulk-logged for full restorability.

```sql
BACKUP DATABASE [MyDB] FILEGROUP = N'FG_2024' TO DISK = N'E:\Backups\MyDB_FG2024.bak'
WITH COMPRESSION, CHECKSUM;
```

### Partial backup

Backs up the primary filegroup plus all read-write filegroups, skipping read-only filegroups (which you back up once). Ideal for VLDBs with large static/archive data.

```sql
BACKUP DATABASE [MyDB] READ_WRITE_FILEGROUPS TO DISK = N'E:\Backups\MyDB_Partial.bak'
WITH COMPRESSION, CHECKSUM;
```

## Backup Options

| Option | Effect | Notes |
|---|---|---|
| `COMPRESSION` | Compresses the backup | Standard+ since 2016 SP1; usually 3–4× smaller and faster (less I/O). Limited gain on TDE/columnstore data. |
| `CHECKSUM` | Validates page checksums during backup; stores a backup checksum | Always use it. Enables `RESTORE VERIFYONLY ... WITH CHECKSUM`. |
| `INIT` / `NOINIT` | Overwrite vs append to the media set | Prefer `INIT` with one backup per file; appending grows files unboundedly and complicates restore. |
| `FORMAT` | Reinitializes the entire media header | Destroys all backup sets on the media — use deliberately. |
| `STATS = n` | Progress reporting every n% | Cosmetic, handy for long backups. |
| `ENCRYPTION (...)` | Encrypts the backup (2014+) | Requires a server certificate or asymmetric key; **back up that certificate + private key separately** or the backup is unrecoverable. |
| `MAXTRANSFERSIZE` / `BUFFERCOUNT` | I/O tuning | Larger transfer size can speed large/striped backups and is required to combine TDE + compression effectively (2016+). |
| `MIRROR TO` | Writes a second copy simultaneously (Enterprise) | Supports the 3-2-1 second copy in one operation. |

### Encrypted backups

```sql
-- [SECURITY CHANGE] Creates keys/certs in master. Source every secret from a secret manager;
-- never commit it, and avoid leaving it in T-SQL/shell history (it lands in plan cache + error logs if mistyped).
-- One-time: a DMK + server certificate in master
USE master;
CREATE MASTER KEY ENCRYPTION BY PASSWORD = N'<generate-32+char-random-secret>';   -- if not present
CREATE CERTIFICATE [BackupCert] WITH SUBJECT = N'Backup Encryption Certificate';

-- Back up the certificate AND its private key off-box (critical)
BACKUP CERTIFICATE [BackupCert]
TO FILE = N'E:\Keys\BackupCert.cer'
WITH PRIVATE KEY (FILE = N'E:\Keys\BackupCert.pvk',
                  ENCRYPTION BY PASSWORD = N'<generate-32+char-random-secret>');

-- Now encrypted backups
BACKUP DATABASE [MyDB] TO DISK = N'E:\Backups\MyDB_Enc.bak'
WITH COMPRESSION, CHECKSUM,
     ENCRYPTION (ALGORITHM = AES_256, SERVER CERTIFICATE = [BackupCert]);
```

> **This private-key password is required to restore the certificate on another instance.** Lose it and every backup encrypted with that cert is **permanently unrecoverable**. Store the password and the `.cer`/`.pvk` pair in a secret manager / key vault under long retention, separate from the backups themselves, and rotate any value ever pasted from documentation. For TDE and key-management depth, route to **sqlserver-security**.

### BACKUP TO URL — Azure Blob and S3

**Azure Blob Storage** (2012 SP1+ / 2016+ matured) — back up directly to a blob container via a credential. Block blobs with a SAS token are recommended. Size limits (block blob): a **single URL** is capped near **~195.3 GB** (50,000 blocks × 4 MB `MAXTRANSFERSIZE`), and **striping across up to 64 URLs** raises the aggregate ceiling to **~12.8 TB**. Even for smaller backups, stripe to avoid hitting the per-blob block limit. Verify the current single-URL vs striped limits on [Microsoft Learn](https://learn.microsoft.com/en-us/sql/relational-databases/backup-restore/sql-server-backup-to-url) for your build.

```sql
-- [SECURITY CHANGE] Credential using a Shared Access Signature (SAS) token.
-- Never commit a real SAS token: scope it (this container, write-only) and give it a short expiry; rotate on exposure.
-- Source the token from a secret manager — it grants storage access and lands in history/error logs if mishandled.
CREATE CREDENTIAL [https://myacct.blob.core.windows.net/backups]
WITH IDENTITY = N'SHARED ACCESS SIGNATURE', SECRET = N'<generate-scoped-short-lived-SAS-token>';

BACKUP DATABASE [MyDB]
TO URL = N'https://myacct.blob.core.windows.net/backups/MyDB_Full.bak'
WITH COMPRESSION, CHECKSUM, FORMAT, STATS = 5;
```

**S3-compatible object storage** — **SQL Server 2022+ only**. Uses the `s3://` scheme with an S3 credential; supports multi-part striping.

```sql
-- [SECURITY CHANGE] 2022+: credential for an S3 endpoint. Use a least-privilege IAM key scoped to this bucket.
-- Source the access/secret keys from a secret manager; never commit them; rotate on exposure.
CREATE CREDENTIAL [s3://s3.us-east-1.amazonaws.com/my-bucket]
WITH IDENTITY = N'S3 Access Key',
     SECRET = N'<access-key-id>:<generate-32+char-random-secret>';

BACKUP DATABASE [MyDB]
TO URL = N's3://s3.us-east-1.amazonaws.com/my-bucket/MyDB_Full.bak'
WITH COMPRESSION, CHECKSUM, FORMAT, STATS = 5;   -- 2022+
```

> **Platform note:** On **Azure SQL DB/MI** you do not run `BACKUP DATABASE` for operational backups (managed). MI permits `COPY_ONLY` `BACKUP ... TO URL` for export/migration only. On **AWS RDS**, native backup/restore uses `rdsadmin.dbo.rds_backup_database` / `rds_restore_database` to/from S3 — not `BACKUP DATABASE`.

### T-SQL snapshot backup (SQL Server 2022+)

SQL Server 2022 added **T-SQL snapshot backup**, which decouples the storage-vendor snapshot from SQL Server's own metadata. You **freeze** I/O for the database, take a storage/volume snapshot externally, then **thaw** and record the snapshot as a backup whose file holds only metadata (`.bkm`). This makes near-instant backup/restore of very large databases possible without the I/O cost of streaming the data. `METADATA_ONLY` and `SNAPSHOT` are synonyms; `BACKUP GROUP` / `BACKUP SERVER` freeze multiple databases sharing a volume at once.

```sql
-- [CONFIG CHANGE] Suspends I/O for the DB until you thaw — keep the freeze window very short. Confirm DB via DB_NAME().
-- 1) Freeze the database (per-DB; ALTER SERVER CONFIGURATION SET SUSPEND_FOR_SNAPSHOT_BACKUP = ON freezes all on a shared disk)
ALTER DATABASE [MyDB] SET SUSPEND_FOR_SNAPSHOT_BACKUP = ON;
-- 2) Take the storage/array snapshot of the data + log volumes here (vendor tool / Azure / array).
-- 3) Record the snapshot as a metadata-only backup (this also thaws the database):
BACKUP DATABASE [MyDB] TO DISK = N'E:\Backups\MyDB_Snap.bkm' WITH METADATA_ONLY, FORMAT;
```

### Accelerated Database Recovery (ADR) and the log

**ADR** (SQL Server **2019+**, and Azure SQL DB/MI; all box editions in 2022 per the editions matrix) changes recovery internals so a **long-running or uncommitted transaction no longer pins the log**: the persisted version store (PVS) and a logical-revert mechanism let the log truncate past an open transaction, and instance recovery/rollback becomes near-instant regardless of transaction size. Operationally this defuses the classic "one giant open transaction blew up the log" incident — but ADR's PVS lives **inside the user database** and consumes space, so account for it when sizing. Enabling/disabling ADR is an `ALTER DATABASE ... SET ACCELERATED_DATABASE_RECOVERY` change — see **sqlserver-infrastructure** for sizing/PVS tuning.

## RPO / RTO Math

- **RPO (Recovery Point Objective)** — the maximum acceptable *data loss*. With log backups every N minutes, your worst-case loss is ~N minutes (plus exposure if the last log backup's media is also lost). To get RPO well below your log interval, use a synchronous replica (Always On AG) — see **sqlserver-ha-clustering**. Simple recovery's RPO is "everything since the last full/diff."
- **RTO (Recovery Time Objective)** — the maximum acceptable *downtime*. Restore time ≈ time to restore the full + the diff + replay all log backups since the diff + crash recovery + tail-log restore. Differentials exist specifically to reduce the number of logs to replay and thus shrink RTO.

**Worked example.** Full nightly at 02:00; logs every 15 minutes; failure at 16:07.
- Without diffs: restore full + replay ~56 log backups (02:15 … 16:00) + tail-log → potentially long RTO.
- With a diff every 6 hours (08:00, 14:00): restore full + 14:00 diff + replay ~8 logs (14:15 … 16:00) + tail-log → far shorter RTO, same ~15-minute RPO.

Tune the **log interval to hit RPO** and the **diff interval to hit RTO**.

## Restore Sequences

### Full → differential → log

```sql
-- [DATA-LOSS RISK] WITH REPLACE OVERWRITES the target DB — confirm you are on the right instance/DB first.
-- Placeholder [MyDB]. (Restore tutorial: stays runnable because the lesson IS the restore sequence.)
-- Restore full, stay in recovering state
RESTORE DATABASE [MyDB] FROM DISK = N'E:\Backups\MyDB_Full.bak'
WITH NORECOVERY, REPLACE;

-- Latest differential
RESTORE DATABASE [MyDB] FROM DISK = N'E:\Backups\MyDB_Diff.bak'
WITH NORECOVERY;

-- All log backups since the diff, in order
RESTORE LOG [MyDB] FROM DISK = N'E:\Backups\MyDB_Log_1.trn' WITH NORECOVERY;
RESTORE LOG [MyDB] FROM DISK = N'E:\Backups\MyDB_Log_2.trn' WITH NORECOVERY;

-- Bring online
RESTORE DATABASE [MyDB] WITH RECOVERY;
```

`WITH MOVE` relocates files when restoring to a different path/instance:

```sql
-- [DATA-LOSS RISK] WITH REPLACE OVERWRITES the target — confirm instance/DB. Restoring to a *separate* test DB
-- name (as here) is the safe pattern for a restore-test; placeholder [MyDB_Test].
RESTORE DATABASE [MyDB_Test] FROM DISK = N'E:\Backups\MyDB_Full.bak'
WITH MOVE N'MyDB'     TO N'E:\Data\MyDB_Test.mdf',
     MOVE N'MyDB_log' TO N'L:\Log\MyDB_Test_log.ldf',
     NORECOVERY, REPLACE;
```

### Tail-log backup

Before overwriting a damaged database, capture the *tail* of the log to recover transactions that occurred after the last log backup (this is what makes near-zero data loss possible):

```sql
-- Database online/accessible
BACKUP LOG [MyDB] TO DISK = N'E:\Backups\MyDB_Tail.trn' WITH NORECOVERY;

-- Database damaged/offline (skip the consistency check)
BACKUP LOG [MyDB] TO DISK = N'E:\Backups\MyDB_Tail.trn'
WITH NO_TRUNCATE, NORECOVERY, CONTINUE_AFTER_ERROR;
```

Then restore it last (before final `WITH RECOVERY`) as the most recent log in the chain.

### Point-in-time restore (STOPAT)

To recover to a moment (e.g., just before an accidental `DELETE`), replay logs and stop at the timestamp on the log that contains it:

```sql
-- [DATA-LOSS RISK] WITH REPLACE OVERWRITES the target DB — confirm instance/DB. Placeholder [MyDB].
RESTORE DATABASE [MyDB] FROM DISK = N'E:\Backups\MyDB_Full.bak' WITH NORECOVERY, REPLACE;
RESTORE LOG [MyDB] FROM DISK = N'E:\Backups\MyDB_Log_1.trn' WITH NORECOVERY;
RESTORE LOG [MyDB] FROM DISK = N'E:\Backups\MyDB_Log_2.trn'
WITH STOPAT = N'2026-05-27T14:31:59', RECOVERY;
```

`STOPATMARK` / `STOPBEFOREMARK` stop at a named transaction mark instead of a clock time. Bulk-logged caveat: you cannot STOPAT inside an interval containing a minimally-logged operation.

> **Platform note:** Azure SQL DB/MI offer **point-in-time restore** through the service (portal / `RESTORE`-style PowerShell / T-SQL) within the configured PITR retention — you pick the timestamp and the service rebuilds from its managed backups. RDS point-in-time restore is via the RDS API/console using automated backups.

### Page restore

When only a few pages are corrupt (and the rest of the DB is fine), restore just those pages instead of the whole database. Online page restore is **Enterprise**; offline on Standard. Requires Full/Bulk-logged and the full log chain since the page was last good.

```sql
-- [DATA-LOSS RISK] Modifies the live DB (replaces the named pages) — confirm instance/DB. Placeholder [MyDB].
RESTORE DATABASE [MyDB] PAGE = N'1:57613, 1:57614'
FROM DISK = N'E:\Backups\MyDB_Full.bak' WITH NORECOVERY;
RESTORE LOG [MyDB] FROM DISK = N'E:\Backups\MyDB_Log_1.trn' WITH NORECOVERY;
-- Take and apply a fresh tail-log, then:
RESTORE DATABASE [MyDB] WITH RECOVERY;
```

Identify bad pages from `msdb.dbo.suspect_pages`, the error log (823/824), or `DBCC CHECKDB` output.

### Piecemeal and online restore (Enterprise)

For VLDBs, restore the primary filegroup first and bring the database **online** while remaining filegroups restore in the background (online piecemeal restore is an Enterprise feature). This lets users access read-write data while archive filegroups recover.

```sql
-- Bring PRIMARY online first
RESTORE DATABASE [MyDB] FILEGROUP = N'PRIMARY'
FROM DISK = N'E:\Backups\MyDB_Partial.bak' WITH PARTIAL, NORECOVERY;
RESTORE LOG [MyDB] FROM DISK = N'E:\Backups\MyDB_Log.trn' WITH RECOVERY;
-- Database is now online; restore remaining filegroups separately, then recover them.
```

## Validation and Testing

```sql
-- Verify a backup is readable and complete (not a guarantee of restorability)
RESTORE VERIFYONLY FROM DISK = N'E:\Backups\MyDB_Full.bak' WITH CHECKSUM;

-- Inspect backup metadata
RESTORE HEADERONLY  FROM DISK = N'E:\Backups\MyDB_Full.bak';
RESTORE FILELISTONLY FROM DISK = N'E:\Backups\MyDB_Full.bak';
```

**The only true validation is a test restore.** Periodically (monthly is common; quarterly minimum for a full DR drill) restore to a scratch instance and run `DBCC CHECKDB` on the result. Automate this and alert on failure. An untested backup is not a backup.

> **Community tools.** The Brent Ozar First Responder Kit (MIT) adds two backup-focused procs: **`sp_BlitzBackups`** estimates real **RPO/RTO from `msdb` backup history** (read-only — a fast check that cadence meets target), and **`sp_DatabaseRestore`** scripts a multi-file restore and pairs with Ola `DatabaseBackup` output (**mutating — [DATA-LOSS RISK]**; confirm target instance/DB). Installing the kit is a **[CONFIG CHANGE]** (objects in a utility DB). See **sqlserver-monitoring** for the full catalog.

## The 3-2-1 Rule

- **3** copies of the data (production + 2 backups).
- **2** different media types (e.g., local disk + cloud/tape).
- **1** copy offsite (different building/region — protects against site loss/ransomware).

`BACKUP ... MIRROR TO` (Enterprise) writes two copies in one operation; combine with an offsite/cloud copy (URL/S3) to satisfy the rule.

## Backup Chains and log_reuse_wait_desc

A backup chain is the ordered set of backups (by LSN) needed to restore: a full, an optional diff, and the unbroken sequence of log backups. The chain **breaks** if you switch to Simple (and back), restore over the database, or lose/skip a log backup. After any break, take a new full to start a fresh chain.

`sys.databases.log_reuse_wait_desc` tells you why the log is not being truncated/reused — critical when the log won't shrink or keeps growing:

| `log_reuse_wait_desc` | Meaning / fix |
|---|---|
| `NOTHING` | Log can be reused; healthy. |
| `LOG_BACKUP` | Full/Bulk-logged DB awaiting a `BACKUP LOG`. Take one. |
| `ACTIVE_TRANSACTION` | A long-running/open transaction is pinning the log. Find/resolve it. |
| `CHECKPOINT` | A checkpoint hasn't completed yet (transient). |
| `ACTIVE_BACKUP_OR_RESTORE` | A backup/restore is in progress. |
| `REPLICATION` / `DATABASE_MIRRORING` / `AVAILABILITY_REPLICA` | Replication/mirroring/AG hasn't consumed the log. Check the feature's health. |
| `OLDEST_PAGE` | Indirect checkpoint target not yet flushed. |

```sql
SELECT name, recovery_model_desc, log_reuse_wait_desc
FROM sys.databases ORDER BY name;
```

**LSN continuity hint:** the `first_lsn` of each log backup must equal the `last_lsn` of the previous one in the chain. `scripts/03-backup-chain-health.sql` surfaces gaps from `msdb.dbo.backupset`.

## Retention and Long-Term Retention (LTR)

- Define retention from compliance + RPO/RTO: e.g., keep 14–35 days of fulls/diffs/logs for operational recovery, and monthly/yearly archive backups for years to meet regulation.
- On box/VM, **Ola Hallengren's `DatabaseBackup`** (or your backup tool) handles cleanup by age; ensure cleanup never deletes a backup still needed by the active chain.
- **Azure SQL DB/MI**: short-term PITR retention is configurable **1–35 days**; **LTR** policies retain weekly/monthly/yearly backups up to **10 years**. **RDS**: automated-backup retention is 0–35 days; use manual snapshots for longer.
- Keep the **encryption certificate/keys** under their own long retention — losing the key makes every encrypted backup unrecoverable.
