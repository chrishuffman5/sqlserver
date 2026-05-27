/*******************************************************************************
 * SQL Server Operations - Backup Status
 *
 * Purpose : Report last full/diff/log backup per database, backup age versus
 *           recovery model, databases lacking recent backups, a recovery-model
 *           audit, and backup size with compression ratio.
 * Version : 1.0.0
 * Targets : SQL Server 2016+ (box / Azure VM). On Managed Instance backups are
 *           managed by the service; msdb.dbo.backupset still reflects COPY_ONLY
 *           backups you take. NOT applicable to Azure SQL Database (no msdb
 *           backup history; backups are fully managed).
 * Safety  : READ-ONLY. Queries msdb backup history and sys.databases only.
 *           No data or configuration is modified.
 *
 * Sections:
 *   1. Last Full / Diff / Log Backup Per Database (+ age vs recovery model)
 *   2. Databases With No Recent Backup (flagged)
 *   3. Recovery Model Audit
 *   4. Backup Size & Compression Ratio (recent backups)
 ******************************************************************************/
SET NOCOUNT ON;

/*──────────────────────────────────────────────────────────────────────────────
  Platform guard: Azure SQL Database has no msdb backup history.
──────────────────────────────────────────────────────────────────────────────*/
IF SERVERPROPERTY('EngineEdition') = 5
BEGIN
    SELECT 'Azure SQL Database: backups are fully managed by the service. '
         + 'Use the portal / sys.dm_database_backups (PITR) instead of msdb history.' AS info_message;
    RETURN;
END;

/*──────────────────────────────────────────────────────────────────────────────
  Section 1: Last Full / Diff / Log Backup Per Database (+ age vs recovery model)
  Backup types: D=full, I=differential, L=log, F=file, G=file diff, P/Q=partial.
──────────────────────────────────────────────────────────────────────────────*/
SELECT
    d.name                                              AS database_name,
    d.recovery_model_desc                               AS recovery_model,
    d.state_desc                                        AS db_state,
    MAX(CASE WHEN b.type = 'D' THEN b.backup_finish_date END) AS last_full_backup,
    MAX(CASE WHEN b.type = 'I' THEN b.backup_finish_date END) AS last_diff_backup,
    MAX(CASE WHEN b.type = 'L' THEN b.backup_finish_date END) AS last_log_backup,
    DATEDIFF(HOUR,
        MAX(CASE WHEN b.type = 'D' THEN b.backup_finish_date END), GETDATE()) AS full_age_hours,
    DATEDIFF(MINUTE,
        MAX(CASE WHEN b.type = 'L' THEN b.backup_finish_date END), GETDATE()) AS log_age_minutes,
    CASE
        WHEN d.recovery_model_desc IN ('FULL','BULK_LOGGED')
             AND MAX(CASE WHEN b.type = 'L' THEN b.backup_finish_date END) IS NULL
            THEN 'WARNING: FULL/BULK-LOGGED with NO log backup (log will grow)'
        WHEN MAX(CASE WHEN b.type = 'D' THEN b.backup_finish_date END) IS NULL
            THEN 'WARNING: no FULL backup on record'
        ELSE 'ok'
    END                                                 AS assessment
FROM sys.databases AS d
LEFT JOIN msdb.dbo.backupset AS b
    ON b.database_name = d.name
WHERE d.source_database_id IS NULL          -- exclude snapshots
GROUP BY d.name, d.recovery_model_desc, d.state_desc
ORDER BY d.name;

/*──────────────────────────────────────────────────────────────────────────────
  Section 2: Databases With No Recent Backup (flagged)
  Thresholds are conventions; adjust to your RPO/RTO policy.
    - Full older than 24h  -> stale full
    - Log older than 60m on FULL/BULK_LOGGED -> RPO at risk
──────────────────────────────────────────────────────────────────────────────*/
;WITH last_bk AS (
    SELECT d.name, d.recovery_model_desc,
           MAX(CASE WHEN b.type = 'D' THEN b.backup_finish_date END) AS last_full,
           MAX(CASE WHEN b.type = 'L' THEN b.backup_finish_date END) AS last_log
    FROM sys.databases d
    LEFT JOIN msdb.dbo.backupset b ON b.database_name = d.name
    WHERE d.source_database_id IS NULL
      AND d.database_id <> 2            -- tempdb is never backed up
    GROUP BY d.name, d.recovery_model_desc
)
SELECT name AS database_name, recovery_model_desc, last_full, last_log,
       CASE WHEN last_full IS NULL OR last_full < DATEADD(HOUR, -24, GETDATE())
            THEN 'STALE/MISSING FULL' ELSE 'ok' END AS full_status,
       CASE WHEN recovery_model_desc IN ('FULL','BULK_LOGGED')
                 AND (last_log IS NULL OR last_log < DATEADD(MINUTE, -60, GETDATE()))
            THEN 'STALE/MISSING LOG' ELSE 'ok' END AS log_status
FROM last_bk
WHERE last_full IS NULL OR last_full < DATEADD(HOUR, -24, GETDATE())
   OR (recovery_model_desc IN ('FULL','BULK_LOGGED')
       AND (last_log IS NULL OR last_log < DATEADD(MINUTE, -60, GETDATE())))
ORDER BY name;

/*──────────────────────────────────────────────────────────────────────────────
  Section 3: Recovery Model Audit
  Surface user databases in SIMPLE (no PITR) and FULL DBs that may need logs.
──────────────────────────────────────────────────────────────────────────────*/
SELECT
    name                                                AS database_name,
    recovery_model_desc                                 AS recovery_model,
    log_reuse_wait_desc,
    CASE
        WHEN database_id > 4 AND recovery_model_desc = 'SIMPLE'
            THEN 'Note: SIMPLE -> no point-in-time recovery. Intentional?'
        WHEN recovery_model_desc IN ('FULL','BULK_LOGGED')
            THEN 'Requires regular LOG backups'
        ELSE ''
    END                                                 AS note
FROM sys.databases
WHERE source_database_id IS NULL
ORDER BY CASE WHEN database_id > 4 THEN 1 ELSE 0 END, name;

/*──────────────────────────────────────────────────────────────────────────────
  Section 4: Backup Size & Compression Ratio (recent backups, last 7 days)
  compressed_backup_size is populated when WITH COMPRESSION was used.
──────────────────────────────────────────────────────────────────────────────*/
SELECT TOP (200)
    b.database_name,
    CASE b.type WHEN 'D' THEN 'Full' WHEN 'I' THEN 'Diff' WHEN 'L' THEN 'Log'
                WHEN 'F' THEN 'File' WHEN 'G' THEN 'FileDiff'
                WHEN 'P' THEN 'Partial' WHEN 'Q' THEN 'PartialDiff'
                ELSE b.type END                         AS backup_type,
    b.backup_finish_date,
    CAST(b.backup_size            / 1024.0 / 1024.0 AS DECIMAL(18,2)) AS data_size_mb,
    CAST(b.compressed_backup_size / 1024.0 / 1024.0 AS DECIMAL(18,2)) AS on_disk_size_mb,
    CASE WHEN b.compressed_backup_size > 0
         THEN CAST(b.backup_size * 1.0 / b.compressed_backup_size AS DECIMAL(6,2))
         ELSE NULL END                                  AS compression_ratio,
    CASE WHEN b.compressed_backup_size > 0
              AND b.compressed_backup_size < b.backup_size
         THEN 'compressed' ELSE 'not compressed' END    AS compression_status
FROM msdb.dbo.backupset AS b
WHERE b.backup_finish_date >= DATEADD(DAY, -7, GETDATE())
ORDER BY b.backup_finish_date DESC;

/*──────────────────────────────────────────────────────────────────────────────
  RECOMMENDATION TEMPLATES (commented out — review before running anywhere):

  -- Take a log backup for a FULL-recovery DB whose log is growing:
  -- BACKUP LOG [MyDB] TO DISK = N'E:\Backups\MyDB_Log.trn'
  --   WITH COMPRESSION, CHECKSUM, INIT;

  -- Switch a dev/test DB that does not need PITR to SIMPLE:
  -- ALTER DATABASE [MyDB] SET RECOVERY SIMPLE;
──────────────────────────────────────────────────────────────────────────────*/
