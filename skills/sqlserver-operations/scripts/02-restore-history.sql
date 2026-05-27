/*******************************************************************************
 * SQL Server Operations - Restore History
 *
 * Purpose : Show what was restored, when, by whom, from which backup, and to
 *           which files. Useful for auditing refreshes, recoveries, and
 *           accidental/unexpected restores.
 * Version : 1.0.0
 * Targets : SQL Server 2016+ (box / Azure VM / Managed Instance).
 *           NOT applicable to Azure SQL Database (no msdb restore history;
 *           restores are performed by the service / portal).
 * Safety  : READ-ONLY. Queries msdb restore history tables only.
 *
 * Sections:
 *   1. Restore Events (who / what / when / type / target)
 *   2. Restored Files Detail (logical -> physical mapping)
 *   3. Restore Summary By Database
 ******************************************************************************/
SET NOCOUNT ON;

/*──────────────────────────────────────────────────────────────────────────────
  Platform guard.
──────────────────────────────────────────────────────────────────────────────*/
IF SERVERPROPERTY('EngineEdition') = 5
BEGIN
    SELECT 'Azure SQL Database: restore history is not exposed via msdb. '
         + 'Use the portal / Get-AzSqlDatabaseRestorePoint for PITR details.' AS info_message;
    RETURN;
END;

/*──────────────────────────────────────────────────────────────────────────────
  Section 1: Restore Events (who / what / when / type / target)
  restore_type: D=database, F=file, I=differential, L=log, V=verifyonly,
                R=revert (snapshot).
──────────────────────────────────────────────────────────────────────────────*/
SELECT TOP (200)
    rh.destination_database_name                        AS restored_to_database,
    CASE rh.restore_type
        WHEN 'D' THEN 'Database (full)'
        WHEN 'I' THEN 'Differential'
        WHEN 'L' THEN 'Log'
        WHEN 'F' THEN 'File'
        WHEN 'V' THEN 'VerifyOnly'
        WHEN 'R' THEN 'Revert (snapshot)'
        ELSE rh.restore_type
    END                                                 AS restore_type,
    rh.restore_date,
    rh.user_name                                        AS performed_by,
    bs.database_name                                    AS source_database,
    bmf.physical_device_name                            AS source_backup_file,
    rh.replace                                          AS used_replace,
    rh.stop_at                                          AS point_in_time_stopat
FROM msdb.dbo.restorehistory AS rh
LEFT JOIN msdb.dbo.backupset AS bs
    ON rh.backup_set_id = bs.backup_set_id
LEFT JOIN msdb.dbo.backupmediafamily AS bmf
    ON bs.media_set_id = bmf.media_set_id
ORDER BY rh.restore_date DESC;

/*──────────────────────────────────────────────────────────────────────────────
  Section 2: Restored Files Detail (logical -> physical mapping)
──────────────────────────────────────────────────────────────────────────────*/
SELECT TOP (300)
    rh.destination_database_name                        AS restored_to_database,
    rh.restore_date,
    rf.destination_phys_name                            AS restored_physical_file,
    bf.logical_name                                     AS source_logical_name,
    bf.file_type                                        AS file_type,    -- D=data, L=log, F=fulltext
    CAST(bf.file_size / 1024.0 / 1024.0 AS DECIMAL(18,2)) AS file_size_mb
FROM msdb.dbo.restorehistory AS rh
JOIN msdb.dbo.restorefile AS rf
    ON rh.restore_history_id = rf.restore_history_id
LEFT JOIN msdb.dbo.backupfile AS bf
    ON rh.backup_set_id = bf.backup_set_id
   AND rf.file_number   = bf.file_number
ORDER BY rh.restore_date DESC, rf.destination_phys_name;

/*──────────────────────────────────────────────────────────────────────────────
  Section 3: Restore Summary By Database (counts + most recent restore)
──────────────────────────────────────────────────────────────────────────────*/
SELECT
    destination_database_name                           AS database_name,
    COUNT(*)                                            AS total_restores,
    MAX(restore_date)                                   AS most_recent_restore,
    MIN(restore_date)                                   AS earliest_recorded_restore
FROM msdb.dbo.restorehistory
GROUP BY destination_database_name
ORDER BY most_recent_restore DESC;
