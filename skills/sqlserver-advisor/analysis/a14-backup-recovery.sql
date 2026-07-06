-- =====================================================================
-- a14-backup-recovery.sql  —  dimension: Configuration (backup & recovery)
-- PREREQUISITE: run analysis/00-load.sql first.
-- FINDS backup-cadence and recovery-model smells from the backup_history and
-- db_inventory captures:
--   (1) database has NEVER had a full backup;
--   (2) last full backup is stale (> 7 days; High > 30 days);
--   (3) FULL/BULK_LOGGED recovery with no (or stale > 24 h) log backups —
--       the log grows unbounded AND point-in-time recovery is fiction;
--   (4) log reuse blocked (log_reuse_wait_desc actionable, e.g. LOG_BACKUP);
--   (5) SIMPLE recovery on a sizable database — confirm the RPO is accepted;
--   (6) last full backup taken WITHOUT CHECKSUM.
-- Depth: sqlserver-operations (backup-recovery.md).
-- NOTE: platform-managed backups (Azure SQL DB/MI automatic, RDS/Cloud SQL
--   snapshots) do NOT appear in msdb.backupset — on managed platforms these
--   findings describe USER-taken backups only; PITR is the platform's job.
--   TRY_CAST guards: an all-NULL date column in the CSV loads as VARCHAR.
-- =====================================================================

-- (1) Never backed up
SELECT
    'Configuration'                                         AS dimension,
    b.database_name                                         AS database_name,
    '(database) ' || b.database_name                        AS object_name,
    CASE WHEN COALESCE(d.database_id, 5) > 4 THEN 'High' ELSE 'Medium' END  AS severity,
    'last_full_backup=NULL; recovery_model=' || b.recovery_model_desc
        || '; size=' || fmt_n(COALESCE(d.total_size_mb, 0)) || ' MB'        AS metric,
    'Database has never had a full backup (none in msdb history).'          AS finding,
    'Take a full backup now and schedule a cadence matched to the RPO; on managed platforms confirm the platform backup covers this DB. [INVESTIGATE]' AS recommendation,
    'Without a full backup there is no restore path at all — any corruption, deletion, or disaster is unrecoverable data loss.' AS why,
    'sqlserver-operations'                                  AS consult_skill
FROM backup_history b
LEFT JOIN db_inventory d ON d.database_name = b.database_name
WHERE TRY_CAST(b.last_full_backup AS TIMESTAMP) IS NULL

UNION ALL
-- (2) Stale full backup
SELECT
    'Configuration', b.database_name, '(database) ' || b.database_name,
    CASE WHEN date_diff('day', TRY_CAST(b.last_full_backup AS TIMESTAMP), b.captured_at) > 30
         THEN 'High' ELSE 'Medium' END,
    'last_full_backup=' || CAST(b.last_full_backup AS VARCHAR)
        || ' (' || date_diff('day', TRY_CAST(b.last_full_backup AS TIMESTAMP), b.captured_at) || ' days ago)'
        || '; fulls_last_30d=' || b.full_backup_count_30d,
    'Most recent full backup is stale.',
    'Restore-test the newest backup you have, then fix the cadence (schedule, alert on failure); confirm the job did not silently stop. [INVESTIGATE]',
    'Every day since the last full widens the restore gap; a backup job that quietly died is one of the most common findings behind real data loss.',
    'sqlserver-operations'
FROM backup_history b
WHERE TRY_CAST(b.last_full_backup AS TIMESTAMP) IS NOT NULL
  AND date_diff('day', TRY_CAST(b.last_full_backup AS TIMESTAMP), b.captured_at) > 7

UNION ALL
-- (3) FULL/BULK_LOGGED recovery without log backups
SELECT
    'Configuration', b.database_name, '(database) ' || b.database_name,
    'High',
    'recovery_model=' || b.recovery_model_desc
        || '; last_log_backup=' || COALESCE(CAST(b.last_log_backup AS VARCHAR), 'NEVER')
        || '; log_backups_last_7d=' || b.log_backup_count_7d,
    'FULL/BULK_LOGGED recovery model but log backups are missing or stale (> 24 h).',
    'Either schedule frequent log backups (typically every 5-15 min, driven by RPO) or deliberately switch to SIMPLE if point-in-time recovery is not required. [CONFIG CHANGE]',
    'In FULL recovery the log only truncates on log backup — without them the log grows until the disk fills, and the point-in-time recovery FULL exists for is not actually available.',
    'sqlserver-operations'
FROM backup_history b
LEFT JOIN db_inventory d ON d.database_name = b.database_name
WHERE b.recovery_model_desc IN ('FULL', 'BULK_LOGGED')
  AND COALESCE(d.database_id, 5) > 4
  AND TRY_CAST(b.last_full_backup AS TIMESTAMP) IS NOT NULL      -- rule (1) already covers never-backed-up
  AND ( TRY_CAST(b.last_log_backup AS TIMESTAMP) IS NULL
        OR date_diff('hour', TRY_CAST(b.last_log_backup AS TIMESTAMP), b.captured_at) > 24 )

UNION ALL
-- (4) Log reuse blocked
SELECT
    'Configuration', d.database_name, '(database) ' || d.database_name,
    CASE WHEN d.log_reuse_wait_desc = 'LOG_BACKUP' THEN 'High' ELSE 'Medium' END,
    'log_reuse_wait=' || d.log_reuse_wait_desc || '; recovery_model=' || d.recovery_model_desc
        || '; size=' || fmt_n(COALESCE(d.total_size_mb, 0)) || ' MB',
    'Transaction-log reuse is blocked (' || d.log_reuse_wait_desc || ').',
    CASE WHEN d.log_reuse_wait_desc = 'LOG_BACKUP'
         THEN 'Take/schedule log backups so the log can truncate; see rule (3). [INVESTIGATE]'
         ELSE 'Investigate the blocker: long-running/orphaned transaction, unsynchronized AG replica, stalled replication agent, or an active scan holding the log. [INVESTIGATE]' END,
    'A blocked log cannot truncate — it grows until the disk fills and the database stops accepting writes (error 9002).',
    'sqlserver-operations'
FROM db_inventory d
WHERE d.database_id > 4 AND d.state_desc = 'ONLINE'
  AND d.log_reuse_wait_desc NOT IN ('NOTHING', 'CHECKPOINT')

UNION ALL
-- (5) SIMPLE recovery on a sizable database (RPO check, informational)
SELECT
    'Configuration', d.database_name, '(database) ' || d.database_name,
    'Low',
    'recovery_model=SIMPLE; size=' || fmt_n(d.total_size_mb) || ' MB',
    'Sizable database runs SIMPLE recovery — no point-in-time restore.',
    'Confirm the business accepts losing everything since the last full/diff backup; if not, switch to FULL and add log backups. [CONFIG CHANGE]',
    'SIMPLE recovery caps the restore point at the last full/differential — fine for rebuildable or staging data, silently dangerous for systems of record.',
    'sqlserver-operations'
FROM db_inventory d
WHERE d.database_id > 4 AND d.recovery_model_desc = 'SIMPLE' AND d.total_size_mb >= 10240

UNION ALL
-- (6) Last full backup taken without CHECKSUM
SELECT
    'Configuration', b.database_name, '(database) ' || b.database_name,
    'Low',
    'last_full_has_checksum=0; last_full_backup=' || CAST(b.last_full_backup AS VARCHAR),
    'Most recent full backup was taken without CHECKSUM.',
    'Add WITH CHECKSUM to backup commands (or enable backup checksum default) and restore-test periodically — a backup is only as good as its last verified restore. [CONFIG CHANGE]',
    'Without CHECKSUM, a backup can faithfully preserve corrupt pages and fail only at restore time — the worst possible moment to find out.',
    'sqlserver-operations'
FROM backup_history b
WHERE TRY_CAST(b.last_full_backup AS TIMESTAMP) IS NOT NULL
  AND COALESCE(TRY_CAST(b.last_full_has_checksum AS INTEGER), 1) = 0;
