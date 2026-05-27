/*******************************************************************************
 * Always On Availability Group — Comprehensive Health
 *
 * Purpose : Report AG configuration, replica & database-replica health, send/
 *           redo queues with estimated lag, listener details, automatic seeding
 *           progress, and AG performance counters.
 * Version : SQL Server 2016+ (build 13.x+). Contained-AG / distributed-AG
 *           columns are version-guarded (is_contained is 2022+/16.x only).
 * Targets : Windows (WSFC), Linux (Pacemaker / EXTERNAL), and CLUSTER_TYPE=NONE.
 * Safety  : READ-ONLY. No data, configuration, or failover changes.
 *
 * Sections:
 *   1. AG Configuration (+ contained/distributed where supported)
 *   2. Replica State & Health
 *   3. Database Replica State (sync, send/redo queues, estimated lag)
 *   4. AG Listener Details
 *   5. Automatic Seeding Progress
 *   6. AG Performance Counters
 ******************************************************************************/
SET NOCOUNT ON;

/*──────────────────────────────────────────────────────────────────────────────
  Prerequisite: Always On must be enabled on this instance.
──────────────────────────────────────────────────────────────────────────────*/
IF SERVERPROPERTY('IsHadrEnabled') IS NULL OR SERVERPROPERTY('IsHadrEnabled') <> 1
BEGIN
    SELECT 'Always On Availability Groups are NOT enabled on this instance. '
         + 'Enable via SQL Server Configuration Manager (Windows) or mssql-conf (Linux), '
         + 'then restart the service.' AS info_message;
    RETURN;
END;

/*──────────────────────────────────────────────────────────────────────────────
  Section 1: AG Configuration (+ contained/distributed where supported)
  is_contained exists only on SQL Server 2022 (16.x)+ -> guard with COL_LENGTH.
──────────────────────────────────────────────────────────────────────────────*/
IF COL_LENGTH('sys.availability_groups', 'is_contained') IS NOT NULL
BEGIN
    -- 2022+ : include contained-AG and distributed-AG columns
    EXEC sys.sp_executesql N'
        SELECT
            ag.name                                            AS ag_name,
            ag.is_contained,                                                       -- 2022+
            CASE ag.is_contained
                WHEN 1 THEN ''Yes - contained (own master/msdb travel with the AG)''
                ELSE ''No - traditional AG (script logins/jobs to every replica)''
            END                                                AS contained_desc,  -- 2022+
            ag.is_distributed                                  AS is_distributed_ag,
            ag.cluster_type_desc,
            ag.automated_backup_preference_desc                AS backup_preference,
            ag.failure_condition_level,
            ag.health_check_timeout                            AS health_check_timeout_ms,
            ag.required_synchronized_secondaries_to_commit     AS required_sync_secondaries,
            ag.db_failover                                     AS db_level_health_triggers_failover,
            ag.dtc_support
        FROM sys.availability_groups AS ag
        ORDER BY ag.name;';
END
ELSE
BEGIN
    -- 2016-2019 : no is_contained column
    SELECT
        ag.name                                            AS ag_name,
        CAST('n/a (<2022)' AS VARCHAR(20))                 AS contained_desc,
        ag.is_distributed                                  AS is_distributed_ag,
        ag.cluster_type_desc,
        ag.automated_backup_preference_desc                AS backup_preference,
        ag.failure_condition_level,
        ag.health_check_timeout                            AS health_check_timeout_ms,
        ag.required_synchronized_secondaries_to_commit     AS required_sync_secondaries,
        ag.db_failover                                     AS db_level_health_triggers_failover,
        ag.dtc_support
    FROM sys.availability_groups AS ag
    ORDER BY ag.name;
END;

/*──────────────────────────────────────────────────────────────────────────────
  Section 2: Replica State & Health
──────────────────────────────────────────────────────────────────────────────*/
SELECT
    ag.name                                     AS ag_name,
    ar.replica_server_name,
    ars.role_desc                               AS current_role,
    ar.availability_mode_desc                   AS availability_mode,
    ar.failover_mode_desc                       AS failover_mode,
    ar.seeding_mode_desc                        AS seeding_mode,
    ars.operational_state_desc                  AS operational_state,
    ars.connected_state_desc                    AS connected_state,
    ars.recovery_health_desc                    AS recovery_health,
    ars.synchronization_health_desc             AS sync_health,
    ar.primary_role_allow_connections_desc      AS primary_connections,
    ar.secondary_role_allow_connections_desc    AS secondary_connections,
    ar.endpoint_url,
    ar.session_timeout                          AS session_timeout_sec,
    ar.backup_priority,
    ars.last_connect_error_number,
    ars.last_connect_error_description,
    ars.last_connect_error_timestamp
FROM sys.availability_replicas AS ar
INNER JOIN sys.availability_groups AS ag
    ON ar.group_id = ag.group_id
LEFT JOIN sys.dm_hadr_availability_replica_states AS ars
    ON ar.replica_id = ars.replica_id
ORDER BY ag.name, ars.role_desc DESC, ar.replica_server_name;

/*──────────────────────────────────────────────────────────────────────────────
  Section 3: Database Replica State (sync, send/redo queues, estimated lag)
──────────────────────────────────────────────────────────────────────────────*/
SELECT
    ag.name                                     AS ag_name,
    ar.replica_server_name,
    DB_NAME(drs.database_id)                    AS database_name,
    drs.is_local,
    drs.is_primary_replica,
    drs.synchronization_state_desc              AS sync_state,
    drs.synchronization_health_desc             AS sync_health,
    drs.database_state_desc                     AS db_state,
    drs.is_suspended,
    drs.suspend_reason_desc,
    -- Queue depths (KB)
    drs.log_send_queue_size                     AS log_send_queue_kb,
    drs.log_send_rate                           AS log_send_rate_kb_sec,
    drs.redo_queue_size                         AS redo_queue_kb,
    drs.redo_rate                               AS redo_rate_kb_sec,
    -- Estimated lag (seconds) derived from queue / rate
    CASE WHEN drs.log_send_rate > 0
         THEN CAST(drs.log_send_queue_size * 1.0 / drs.log_send_rate AS DECIMAL(18,2))
    END                                         AS est_send_lag_sec,
    CASE WHEN drs.redo_rate > 0
         THEN CAST(drs.redo_queue_size * 1.0 / drs.redo_rate AS DECIMAL(18,2))
    END                                         AS est_redo_lag_sec,
    drs.last_commit_time,
    drs.last_hardened_time,
    drs.last_redone_time,
    drs.last_sent_time,
    drs.last_received_time,
    drs.last_hardened_lsn,
    drs.last_commit_lsn,
    drs.end_of_log_lsn
FROM sys.dm_hadr_database_replica_states AS drs
INNER JOIN sys.availability_replicas AS ar
    ON drs.replica_id = ar.replica_id
INNER JOIN sys.availability_groups AS ag
    ON ar.group_id = ag.group_id
ORDER BY ag.name, DB_NAME(drs.database_id), ar.replica_server_name;

/*──────────────────────────────────────────────────────────────────────────────
  Section 4: AG Listener Details
──────────────────────────────────────────────────────────────────────────────*/
SELECT
    ag.name                                     AS ag_name,
    agl.dns_name                                AS listener_dns_name,
    agl.port                                    AS listener_port,
    agl.is_conformant,
    aglip.ip_address,
    aglip.ip_subnet_mask,
    aglip.is_dhcp,
    aglip.state_desc                            AS ip_state
FROM sys.availability_group_listeners AS agl
INNER JOIN sys.availability_groups AS ag
    ON agl.group_id = ag.group_id
LEFT JOIN sys.availability_group_listener_ip_addresses AS aglip
    ON agl.listener_id = aglip.listener_id
ORDER BY ag.name, agl.dns_name;

/*──────────────────────────────────────────────────────────────────────────────
  Section 5: Automatic Seeding Progress
  sys.dm_hadr_automatic_seeding tracks the seeding state machine;
  sys.dm_hadr_physical_seeding_stats tracks the in-flight physical transfer.
──────────────────────────────────────────────────────────────────────────────*/
SELECT
    ag.name                                     AS ag_name,
    aut.current_state                           AS seeding_state,
    aut.performed_seeding,
    aut.failure_state_desc                      AS failure_state,
    aut.error_code,
    aut.start_time,
    aut.completion_time
FROM sys.dm_hadr_automatic_seeding AS aut
INNER JOIN sys.availability_groups AS ag
    ON aut.ag_id = ag.group_id
ORDER BY aut.start_time DESC;

-- In-flight physical seeding throughput (rows only present during active seeding)
SELECT
    hps.local_database_name                     AS database_name,
    hps.remote_machine_name                     AS target_replica,
    hps.role_desc                               AS seeding_role,
    hps.transfer_rate_bytes_per_second          AS transfer_rate_bps,
    hps.transferred_size_bytes,
    hps.database_size_bytes,
    CASE WHEN hps.database_size_bytes > 0
         THEN CAST(100.0 * hps.transferred_size_bytes / hps.database_size_bytes AS DECIMAL(5,2))
    END                                         AS pct_complete,
    hps.is_compression_enabled,
    hps.start_time_utc,
    hps.end_time_utc,
    hps.failure_message
FROM sys.dm_hadr_physical_seeding_stats AS hps
ORDER BY hps.start_time_utc DESC;

/*──────────────────────────────────────────────────────────────────────────────
  Section 6: AG Performance Counters
──────────────────────────────────────────────────────────────────────────────*/
SELECT
    RTRIM(object_name)                          AS counter_object,
    RTRIM(counter_name)                         AS counter_name,
    RTRIM(instance_name)                        AS ag_or_db,
    cntr_value                                  AS counter_value
FROM sys.dm_os_performance_counters
WHERE object_name LIKE '%Availability Replica%'
   OR object_name LIKE '%Database Replica%'
ORDER BY object_name, counter_name, instance_name;
