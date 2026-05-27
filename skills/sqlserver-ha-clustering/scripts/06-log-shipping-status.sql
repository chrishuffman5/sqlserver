/*******************************************************************************
 * Log Shipping — Status & Latency
 *
 * Purpose : Report log shipping freshness and alerting state from the msdb
 *           monitor tables: last backup (primary), last copy/restore
 *           (secondary), latency vs configured thresholds, and which roles this
 *           instance plays.
 * Version : SQL Server 2016+ (build 13.x+). Runs against msdb monitor tables.
 * Safety  : READ-ONLY. No log shipping configuration or restore changes.
 *
 * Sections:
 *   0. Guard — is log shipping configured on this instance?
 *   1. Primary-side Status (last log backup, threshold)
 *   2. Secondary-side Status (last copy/restore, latency, threshold)
 *   3. Recent History Detail (backup/copy/restore actions)
 ******************************************************************************/
SET NOCOUNT ON;

/*──────────────────────────────────────────────────────────────────────────────
  Section 0: Guard — the monitor tables exist on any instance, but are empty
  unless log shipping (primary, secondary, or monitor role) is configured here.
──────────────────────────────────────────────────────────────────────────────*/
IF OBJECT_ID('msdb.dbo.log_shipping_monitor_primary')   IS NULL
   AND OBJECT_ID('msdb.dbo.log_shipping_monitor_secondary') IS NULL
BEGIN
    SELECT 'Log shipping monitor tables not found in msdb (unexpected).' AS info_message;
    RETURN;
END;

IF NOT EXISTS (SELECT 1 FROM msdb.dbo.log_shipping_monitor_primary)
   AND NOT EXISTS (SELECT 1 FROM msdb.dbo.log_shipping_monitor_secondary)
BEGIN
    SELECT 'Log shipping is not configured on this instance (no primary or secondary rows '
         + 'in the msdb monitor tables).' AS info_message;
    RETURN;
END;

/*──────────────────────────────────────────────────────────────────────────────
  Section 1: Primary-side Status
  How long since the last log backup, vs the backup threshold.
──────────────────────────────────────────────────────────────────────────────*/
IF EXISTS (SELECT 1 FROM msdb.dbo.log_shipping_monitor_primary)
BEGIN
    SELECT
        p.primary_server,
        p.primary_database,
        p.last_backup_file,
        p.last_backup_date,
        p.last_backup_date_utc,
        DATEDIFF(MINUTE, p.last_backup_date, GETDATE()) AS minutes_since_last_backup,
        p.backup_threshold                          AS backup_threshold_min,
        CASE WHEN DATEDIFF(MINUTE, p.last_backup_date, GETDATE()) > p.backup_threshold
             THEN 'ALERT: backup is older than threshold'
             ELSE 'OK'
        END                                         AS backup_status,
        p.threshold_alert_enabled
    FROM msdb.dbo.log_shipping_monitor_primary AS p
    ORDER BY p.primary_database;
END;

/*──────────────────────────────────────────────────────────────────────────────
  Section 2: Secondary-side Status
  Copy and restore freshness and latency vs the restore threshold.
──────────────────────────────────────────────────────────────────────────────*/
IF EXISTS (SELECT 1 FROM msdb.dbo.log_shipping_monitor_secondary)
BEGIN
    SELECT
        s.secondary_server,
        s.secondary_database,
        s.primary_server,
        s.primary_database,
        s.last_copied_file,
        s.last_copied_date,
        s.last_restored_file,
        s.last_restored_date,
        DATEDIFF(MINUTE, s.last_restored_date, GETDATE()) AS minutes_since_last_restore,
        s.last_restored_latency                     AS last_restored_latency_min,
        s.restore_threshold                         AS restore_threshold_min,
        CASE WHEN s.last_restored_latency > s.restore_threshold
             THEN 'ALERT: restore latency exceeds threshold (secondary falling behind)'
             ELSE 'OK'
        END                                         AS restore_status,
        s.threshold_alert_enabled
    FROM msdb.dbo.log_shipping_monitor_secondary AS s
    ORDER BY s.secondary_database;
END;

/*──────────────────────────────────────────────────────────────────────────────
  Section 3: Recent History Detail (latest action per session)
──────────────────────────────────────────────────────────────────────────────*/
IF OBJECT_ID('msdb.dbo.log_shipping_monitor_history_detail') IS NOT NULL
   AND EXISTS (SELECT 1 FROM msdb.dbo.log_shipping_monitor_history_detail)
BEGIN
    SELECT TOP (200)
        h.agent_type,                               -- 0=Backup, 1=Copy, 2=Restore
        CASE h.agent_type WHEN 0 THEN 'Backup' WHEN 1 THEN 'Copy' WHEN 2 THEN 'Restore'
             ELSE CAST(h.agent_type AS VARCHAR(10)) END AS agent_action,
        h.agent_id,
        h.session_status,                           -- 0=Starting,1=Running,2=Error,3=Warning,4=Success
        h.log_time,
        h.log_time_utc,
        h.message
    FROM msdb.dbo.log_shipping_monitor_history_detail AS h
    ORDER BY h.log_time DESC;
END;
