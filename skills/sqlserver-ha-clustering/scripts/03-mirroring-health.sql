/*******************************************************************************
 * Database Mirroring — Health
 *
 * Purpose : Report database mirroring sessions: state, role, safety level,
 *           witness, partner instance, redo queue, and send/redo throughput
 *           from the 'Database Mirroring' performance object.
 * Version : SQL Server 2016+ (build 13.x+). NOTE: database mirroring is
 *           DEPRECATED (since 2012). Plan migration to Always On AGs (Basic AG
 *           on Standard). See references/mirroring-endpoints.md.
 * Targets : Any instance that may host mirrored databases.
 * Safety  : READ-ONLY. No mirroring state or failover changes.
 *
 * Sections:
 *   1. Mirroring Session State (sys.database_mirroring)
 *   2. Witness Summary
 *   3. Mirroring Performance Counters (send/redo queues, rates)
 *   4. Failover Command Templates (COMMENTED — run deliberately)
 ******************************************************************************/
SET NOCOUNT ON;

/*──────────────────────────────────────────────────────────────────────────────
  Section 1: Mirroring Session State
  mirroring_guid IS NOT NULL  ->  the database participates in mirroring.
──────────────────────────────────────────────────────────────────────────────*/
IF NOT EXISTS (SELECT 1 FROM sys.database_mirroring WHERE mirroring_guid IS NOT NULL)
BEGIN
    SELECT 'No mirrored databases found on this instance. '
         + 'Database mirroring is deprecated — prefer Always On Availability Groups.' AS info_message;
END
ELSE
BEGIN
    SELECT
        DB_NAME(dm.database_id)                 AS database_name,
        dm.mirroring_state_desc                 AS mirroring_state,    -- SYNCHRONIZED/SYNCHRONIZING/SUSPENDED/DISCONNECTED/PENDING_FAILOVER
        dm.mirroring_role_desc                  AS role,               -- PRINCIPAL / MIRROR
        dm.mirroring_role_sequence,
        dm.mirroring_safety_level_desc          AS safety_level,       -- FULL (sync) / OFF (async)
        dm.mirroring_safety_sequence,
        dm.mirroring_partner_name,
        dm.mirroring_partner_instance,
        dm.mirroring_witness_name,
        dm.mirroring_witness_state_desc         AS witness_state,      -- CONNECTED / DISCONNECTED / UNKNOWN
        dm.mirroring_failover_lsn,
        dm.mirroring_connection_timeout         AS connection_timeout_sec,
        dm.mirroring_redo_queue,
        dm.mirroring_redo_queue_type
    FROM sys.database_mirroring AS dm
    WHERE dm.mirroring_guid IS NOT NULL
    ORDER BY database_name;

    /*──────────────────────────────────────────────────────────────────────────
      Section 2: Witness Summary (any session relying on a witness)
    ──────────────────────────────────────────────────────────────────────────*/
    SELECT
        DB_NAME(dm.database_id)                 AS database_name,
        dm.mirroring_witness_name,
        dm.mirroring_witness_state_desc         AS witness_state,
        dm.mirroring_safety_level_desc          AS safety_level,
        CASE
            WHEN dm.mirroring_witness_name IS NOT NULL
             AND dm.mirroring_safety_level_desc = 'FULL'
            THEN 'High Safety + witness -> automatic failover possible'
            WHEN dm.mirroring_safety_level_desc = 'FULL'
            THEN 'High Safety, no witness -> manual failover only'
            ELSE 'High Performance (async) -> forced service only (possible data loss)'
        END                                     AS failover_capability
    FROM sys.database_mirroring AS dm
    WHERE dm.mirroring_guid IS NOT NULL
    ORDER BY database_name;
END;

/*──────────────────────────────────────────────────────────────────────────────
  Section 3: Mirroring Performance Counters (send/redo queues & rates)
  Object name is 'SQLServer:Database Mirroring' (or 'MSSQL$instance:Database
  Mirroring' on a named instance) — match with LIKE on the trimmed object name.
──────────────────────────────────────────────────────────────────────────────*/
SELECT
    RTRIM(object_name)                          AS counter_object,
    RTRIM(counter_name)                         AS counter_name,
    RTRIM(instance_name)                        AS database_name,
    cntr_value                                  AS counter_value
FROM sys.dm_os_performance_counters
WHERE object_name LIKE '%Database Mirroring%'
ORDER BY instance_name, counter_name;

/*──────────────────────────────────────────────────────────────────────────────
  Section 4: FAILOVER / ADMIN TEMPLATES — COMMENTED OUT. Run deliberately only.
──────────────────────────────────────────────────────────────────────────────*/
/*
   -- Planned manual failover (High Safety / sync, NO data loss) — on the PRINCIPAL:
   --   ALTER DATABASE [YourDB] SET PARTNER FAILOVER;

   -- Forced service (async or partner unreachable) *** POSSIBLE DATA LOSS *** — on the MIRROR:
   --   ALTER DATABASE [YourDB] SET PARTNER FORCE_SERVICE_ALLOW_DATA_LOSS;

   -- Resume a SUSPENDED session:
   --   ALTER DATABASE [YourDB] SET PARTNER RESUME;

   -- Migration to Always On AG: remove mirroring, then create/join the AG
   -- (the existing database-mirroring ENDPOINT on port 5022 is reused by the AG):
   --   ALTER DATABASE [YourDB] SET PARTNER OFF;
*/
