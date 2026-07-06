/*******************************************************************************
 * SQL Server Advisor - Collector 14: Backup History
 *
 * Purpose : Capture one row per database (tempdb excluded - it cannot be
 *           backed up) with the most recent full / differential / log backup,
 *           recent backup counts, and the last full backup's size and CHECKSUM
 *           flag, from the msdb backup-history tables. Feeds the backup- and
 *           recovery-cadence analysis (a14-backup-recovery): never backed up,
 *           stale fulls, FULL recovery without log backups, backups taken
 *           without CHECKSUM.
 * Version : 1.0.0
 * Targets : SQL Server 2016-2025 (box / Azure VM / MI / RDS / Cloud SQL).
 * Safety  : READ-ONLY. Reads sys.databases + msdb.dbo.backupset only.
 *
 * Output columns (EXACT capture contract -> capture/backup_history.csv):
 *   server_name, captured_at, database_name, recovery_model_desc,
 *   last_full_backup, last_diff_backup, last_log_backup,
 *   full_backup_count_30d, log_backup_count_7d, last_full_backup_size_mb,
 *   last_full_has_checksum
 *
 * Column semantics:
 *   - COPY_ONLY full backups are EXCLUDED from last_full_backup and the counts:
 *     they do not establish/reset the backup chain, so they must not satisfy a
 *     "recent full exists" check. Log backups are never copy-only-filtered
 *     (copy-only log backups are rare and still protect the chain's tail).
 *   - A database with no history rows still emits one row with NULL backup
 *     dates - that is the "never backed up" signal, and it also guarantees the
 *     CSV is never empty.
 *
 * Permissions : requires read access to the msdb history tables (db_datareader
 *           in msdb, or SQLAgentReader-equivalent). Still strictly read-only.
 *
 * Platform / DMV caveats:
 *   - Azure SQL Database / Managed Instance: platform-managed automatic backups
 *     do NOT appear in msdb.dbo.backupset (on Azure SQL DB there is no msdb at
 *     all - skip this collector there). Backup findings on those platforms are
 *     about USER-taken backups (e.g. MI COPY_ONLY) only; PITR is the platform's
 *     job - see sqlserver-cloud.
 *   - AWS RDS: automated backups are storage snapshots and do NOT appear in
 *     backupset; native .bak backups via rds_backup_database DO. Treat
 *     "no backup" findings as informational unless native backups are the DR
 *     strategy. Cloud SQL behaves similarly.
 ******************************************************************************/
SET NOCOUNT ON;

SELECT
    CONVERT(varchar(256), SERVERPROPERTY('ServerName'))             AS server_name,
    SYSUTCDATETIME()                                                AS captured_at,
    d.name                                                          AS database_name,
    d.recovery_model_desc                                           AS recovery_model_desc,
    bs.last_full_backup                                             AS last_full_backup,
    bs.last_diff_backup                                             AS last_diff_backup,
    bs.last_log_backup                                              AS last_log_backup,
    ISNULL(bs.full_backup_count_30d, 0)                             AS full_backup_count_30d,
    ISNULL(bs.log_backup_count_7d, 0)                               AS log_backup_count_7d,
    bs.last_full_backup_size_mb                                     AS last_full_backup_size_mb,
    bs.last_full_has_checksum                                       AS last_full_has_checksum
FROM sys.databases AS d
OUTER APPLY
(
    SELECT
        MAX(CASE WHEN b.type = 'D' AND b.is_copy_only = 0
                 THEN b.backup_finish_date END)                     AS last_full_backup,
        MAX(CASE WHEN b.type = 'I' AND b.is_copy_only = 0
                 THEN b.backup_finish_date END)                     AS last_diff_backup,
        MAX(CASE WHEN b.type = 'L'
                 THEN b.backup_finish_date END)                     AS last_log_backup,
        SUM(CASE WHEN b.type = 'D' AND b.is_copy_only = 0
                  AND b.backup_finish_date >= DATEADD(DAY, -30, SYSUTCDATETIME())
                 THEN 1 ELSE 0 END)                                 AS full_backup_count_30d,
        SUM(CASE WHEN b.type = 'L'
                  AND b.backup_finish_date >= DATEADD(DAY, -7, SYSUTCDATETIME())
                 THEN 1 ELSE 0 END)                                 AS log_backup_count_7d,
        CAST(MAX(CASE WHEN b.type = 'D' AND b.is_copy_only = 0
                       AND b.backup_finish_date = lastfull.finish_date
                      THEN b.backup_size END) / 1048576.0
             AS DECIMAL(18,2))                                      AS last_full_backup_size_mb,
        MAX(CASE WHEN b.type = 'D' AND b.is_copy_only = 0
                  AND b.backup_finish_date = lastfull.finish_date
                 THEN CONVERT(int, b.has_backup_checksums) END)     AS last_full_has_checksum
    FROM msdb.dbo.backupset AS b
    OUTER APPLY
    (
        SELECT MAX(b2.backup_finish_date) AS finish_date
        FROM msdb.dbo.backupset AS b2
        WHERE b2.database_name = d.name AND b2.type = 'D' AND b2.is_copy_only = 0
    ) AS lastfull
    WHERE b.database_name = d.name
) AS bs
WHERE d.database_id <> 2       -- tempdb cannot be backed up
ORDER BY d.name;
