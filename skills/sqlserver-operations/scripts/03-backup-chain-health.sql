/*******************************************************************************
 * SQL Server Operations - Backup Chain Health
 *
 * Purpose : Assess the health of backup chains: log_reuse_wait_desc per
 *           database, recovery model versus log-backup presence, potential
 *           broken log chains, and LSN-continuity hints between consecutive
 *           log backups.
 * Version : 1.0.0
 * Targets : SQL Server 2016+ (box / Azure VM / Managed Instance).
 *           NOT applicable to Azure SQL Database (backup chain is managed).
 * Safety  : READ-ONLY. Reads sys.databases and msdb backup history only.
 *
 * Sections:
 *   1. Log Reuse Wait (why the log is not being freed) + recovery model
 *   2. Recovery Model vs Log Backup Presence
 *   3. Last Full / Last Diff vs Diff Base (chain reset detection)
 *   4. Log Chain LSN Continuity Hints (gaps between consecutive log backups)
 ******************************************************************************/
SET NOCOUNT ON;

/*──────────────────────────────────────────────────────────────────────────────
  Platform guard.
──────────────────────────────────────────────────────────────────────────────*/
IF SERVERPROPERTY('EngineEdition') = 5
BEGIN
    SELECT 'Azure SQL Database: backup chains are managed by the service.' AS info_message;
    RETURN;
END;

/*──────────────────────────────────────────────────────────────────────────────
  Section 1: Log Reuse Wait + recovery model
  log_reuse_wait_desc tells you WHY the log cannot be truncated/reused.
──────────────────────────────────────────────────────────────────────────────*/
SELECT
    name                                                AS database_name,
    recovery_model_desc                                 AS recovery_model,
    log_reuse_wait_desc,
    CASE log_reuse_wait_desc
        WHEN 'LOG_BACKUP'        THEN 'Take a BACKUP LOG (FULL/BULK_LOGGED awaiting log backup)'
        WHEN 'ACTIVE_TRANSACTION'THEN 'A long/open transaction is pinning the log - investigate'
        WHEN 'AVAILABILITY_REPLICA' THEN 'AG secondary has not hardened the log - check AG health'
        WHEN 'DATABASE_MIRRORING'   THEN 'Mirror has not consumed the log - check mirroring'
        WHEN 'REPLICATION'       THEN 'Replication has not read the log - check log reader agent'
        WHEN 'NOTHING'           THEN 'Healthy - log can be reused'
        ELSE 'See docs for ' + log_reuse_wait_desc
    END                                                 AS guidance
FROM sys.databases
WHERE source_database_id IS NULL
ORDER BY CASE WHEN log_reuse_wait_desc <> 'NOTHING' THEN 0 ELSE 1 END, name;

/*──────────────────────────────────────────────────────────────────────────────
  Section 2: Recovery Model vs Log Backup Presence
  A FULL/BULK_LOGGED database with no log backup has a broken/never-started chain.
──────────────────────────────────────────────────────────────────────────────*/
SELECT
    d.name                                              AS database_name,
    d.recovery_model_desc                               AS recovery_model,
    MAX(CASE WHEN b.type = 'D' THEN b.backup_finish_date END) AS last_full,
    MAX(CASE WHEN b.type = 'L' THEN b.backup_finish_date END) AS last_log,
    CASE
        WHEN d.recovery_model_desc IN ('FULL','BULK_LOGGED')
             AND MAX(CASE WHEN b.type = 'D' THEN b.backup_finish_date END) IS NULL
            THEN 'BROKEN: no FULL to anchor the chain'
        WHEN d.recovery_model_desc IN ('FULL','BULK_LOGGED')
             AND MAX(CASE WHEN b.type = 'L' THEN b.backup_finish_date END) IS NULL
            THEN 'AT RISK: FULL exists but no LOG backups (chain not extended; log grows)'
        WHEN d.recovery_model_desc = 'SIMPLE'
            THEN 'N/A: SIMPLE recovery (no log chain / no PITR)'
        ELSE 'ok'
    END                                                 AS chain_assessment
FROM sys.databases AS d
LEFT JOIN msdb.dbo.backupset AS b ON b.database_name = d.name
WHERE d.source_database_id IS NULL
  AND d.database_id <> 2
GROUP BY d.name, d.recovery_model_desc
ORDER BY d.name;

/*──────────────────────────────────────────────────────────────────────────────
  Section 3: Last Full / Last Diff vs Diff Base (chain reset detection)
  A differential is only restorable on top of the full whose checkpoint LSN
  matches the diff's differential_base_lsn. Mismatch => diff is orphaned.
──────────────────────────────────────────────────────────────────────────────*/
;WITH last_full AS (
    SELECT database_name, MAX(backup_finish_date) AS full_finish,
           MAX(checkpoint_lsn) AS full_checkpoint_lsn
    FROM msdb.dbo.backupset
    WHERE type = 'D'
    GROUP BY database_name
),
last_diff AS (
    SELECT b.database_name, b.backup_finish_date AS diff_finish,
           b.differential_base_lsn,
           ROW_NUMBER() OVER (PARTITION BY b.database_name ORDER BY b.backup_finish_date DESC) AS rn
    FROM msdb.dbo.backupset b
    WHERE b.type = 'I'
)
SELECT
    f.database_name,
    f.full_finish                                       AS last_full_backup,
    d.diff_finish                                       AS last_diff_backup,
    CASE
        WHEN d.diff_finish IS NULL THEN 'No differential on record'
        WHEN d.differential_base_lsn = f.full_checkpoint_lsn
            THEN 'ok: diff base matches last full'
        ELSE 'WARNING: latest diff base does NOT match last full (orphaned diff / newer full taken)'
    END                                                 AS diff_chain_note
FROM last_full f
LEFT JOIN last_diff d ON f.database_name = d.database_name AND d.rn = 1
ORDER BY f.database_name;

/*──────────────────────────────────────────────────────────────────────────────
  Section 4: Log Chain LSN Continuity Hints
  Within a chain, each log backup's first_lsn should equal the previous
  backup's last_lsn. A gap indicates a missing/skipped log backup (broken chain).
  Shows the most recent log backups per DB and flags discontinuities.
──────────────────────────────────────────────────────────────────────────────*/
;WITH log_bk AS (
    SELECT
        database_name,
        backup_finish_date,
        first_lsn,
        last_lsn,
        LAG(last_lsn) OVER (PARTITION BY database_name ORDER BY first_lsn) AS prev_last_lsn
    FROM msdb.dbo.backupset
    WHERE type = 'L'
      AND backup_finish_date >= DATEADD(DAY, -3, GETDATE())
)
SELECT TOP (300)
    database_name,
    backup_finish_date,
    first_lsn,
    last_lsn,
    prev_last_lsn,
    CASE
        WHEN prev_last_lsn IS NULL THEN 'first in window'
        WHEN first_lsn = prev_last_lsn THEN 'ok: contiguous'
        ELSE 'GAP: first_lsn <> previous last_lsn (possible broken log chain)'
    END                                                 AS continuity
FROM log_bk
ORDER BY database_name, first_lsn DESC;
