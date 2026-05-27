/*******************************************************************************
 * Always On Availability Group — Failover Readiness
 *
 * Purpose : Assess whether each AG is ready for a NO-DATA-LOSS failover:
 *           overall sync health, whether every SYNCHRONOUS_COMMIT replica is
 *           SYNCHRONIZED, required-sync-secondaries vs healthy count, suspended
 *           databases, quorum votes, last_commit_time skew (effective RPO), and
 *           automatic-failover-target validity.
 * Version : SQL Server 2016+ (build 13.x+).
 * Targets : Windows (WSFC), Linux (Pacemaker / EXTERNAL), CLUSTER_TYPE=NONE.
 * Safety  : READ-ONLY. No failover is performed — see commented templates only.
 *
 * Sections:
 *   1. Per-AG Readiness Summary
 *   2. Synchronous Replicas Not Yet SYNCHRONIZED (blockers)
 *   3. Suspended Databases & Reasons
 *   4. last_commit_time Skew Across Replicas (effective RPO)
 *   5. Quorum Votes (cluster ability to fail over)
 *   6. Failover Command Templates (COMMENTED — run deliberately)
 ******************************************************************************/
SET NOCOUNT ON;

IF SERVERPROPERTY('IsHadrEnabled') IS NULL OR SERVERPROPERTY('IsHadrEnabled') <> 1
BEGIN
    SELECT 'Always On is NOT enabled on this instance.' AS info_message;
    RETURN;
END;

/*──────────────────────────────────────────────────────────────────────────────
  Section 1: Per-AG Readiness Summary
  Compares required_synchronized_secondaries_to_commit against the count of
  healthy synchronous secondaries that are actually SYNCHRONIZED.
──────────────────────────────────────────────────────────────────────────────*/
SELECT
    ag.name                                                         AS ag_name,
    ag.required_synchronized_secondaries_to_commit                  AS required_sync_secondaries,
    SUM(CASE WHEN ar.availability_mode_desc = 'SYNCHRONOUS_COMMIT'
              AND ars.role_desc = 'SECONDARY'
              AND ars.synchronization_health_desc = 'HEALTHY'
             THEN 1 ELSE 0 END)                                     AS healthy_sync_secondaries,
    SUM(CASE WHEN ar.availability_mode_desc = 'SYNCHRONOUS_COMMIT'
              AND ar.failover_mode_desc = 'AUTOMATIC'
              AND ars.role_desc = 'SECONDARY'
             THEN 1 ELSE 0 END)                                     AS auto_failover_target_replicas,
    MAX(CASE WHEN ars.role_desc = 'PRIMARY'
             THEN ars.synchronization_health_desc END)             AS primary_sync_health,
    CASE
        WHEN SUM(CASE WHEN ar.availability_mode_desc = 'SYNCHRONOUS_COMMIT'
                       AND ar.failover_mode_desc = 'AUTOMATIC'
                       AND ars.role_desc = 'SECONDARY'
                       AND ars.synchronization_health_desc = 'HEALTHY'
                      THEN 1 ELSE 0 END) >= 1
        THEN 'READY: a synchronized automatic-failover target exists (no data loss)'
        ELSE 'NOT READY for automatic / no-data-loss failover — see sections 2-4'
    END                                                            AS readiness_verdict
FROM sys.availability_groups AS ag
INNER JOIN sys.availability_replicas AS ar
    ON ag.group_id = ar.group_id
LEFT JOIN sys.dm_hadr_availability_replica_states AS ars
    ON ar.replica_id = ars.replica_id
GROUP BY ag.name, ag.required_synchronized_secondaries_to_commit
ORDER BY ag.name;

/*──────────────────────────────────────────────────────────────────────────────
  Section 2: Synchronous Replicas/Databases Not Yet SYNCHRONIZED (failover blockers)
  A no-data-loss failover requires the target's databases to be SYNCHRONIZED.
──────────────────────────────────────────────────────────────────────────────*/
SELECT
    ag.name                                     AS ag_name,
    ar.replica_server_name,
    ar.availability_mode_desc                   AS availability_mode,
    ar.failover_mode_desc                       AS failover_mode,
    DB_NAME(drs.database_id)                    AS database_name,
    drs.synchronization_state_desc              AS sync_state,
    drs.synchronization_health_desc             AS sync_health,
    drs.log_send_queue_size                     AS log_send_queue_kb,
    drs.redo_queue_size                         AS redo_queue_kb
FROM sys.dm_hadr_database_replica_states AS drs
INNER JOIN sys.availability_replicas AS ar
    ON drs.replica_id = ar.replica_id
INNER JOIN sys.availability_groups AS ag
    ON ar.group_id = ag.group_id
WHERE ar.availability_mode_desc = 'SYNCHRONOUS_COMMIT'
  AND drs.is_primary_replica = 0
  AND drs.synchronization_state_desc <> 'SYNCHRONIZED'
ORDER BY ag.name, ar.replica_server_name, database_name;

/*──────────────────────────────────────────────────────────────────────────────
  Section 3: Suspended Databases & Reasons
──────────────────────────────────────────────────────────────────────────────*/
SELECT
    ag.name                                     AS ag_name,
    ar.replica_server_name,
    DB_NAME(drs.database_id)                    AS database_name,
    drs.is_suspended,
    drs.suspend_reason_desc,
    drs.synchronization_state_desc              AS sync_state,
    drs.database_state_desc                     AS db_state
FROM sys.dm_hadr_database_replica_states AS drs
INNER JOIN sys.availability_replicas AS ar
    ON drs.replica_id = ar.replica_id
INNER JOIN sys.availability_groups AS ag
    ON ar.group_id = ag.group_id
WHERE drs.is_suspended = 1
ORDER BY ag.name, ar.replica_server_name, database_name;

/*──────────────────────────────────────────────────────────────────────────────
  Section 4: last_commit_time Skew Across Replicas (effective RPO for async)
  The gap between the primary's last_commit_time and a secondary's is roughly
  the data you would lose failing over to that secondary right now.
──────────────────────────────────────────────────────────────────────────────*/
;WITH commits AS (
    SELECT
        ag.name                                 AS ag_name,
        DB_NAME(drs.database_id)                AS database_name,
        ar.replica_server_name,
        drs.is_primary_replica,
        drs.last_commit_time
    FROM sys.dm_hadr_database_replica_states AS drs
    INNER JOIN sys.availability_replicas AS ar ON drs.replica_id = ar.replica_id
    INNER JOIN sys.availability_groups   AS ag ON ar.group_id = ag.group_id
)
SELECT
    s.ag_name,
    s.database_name,
    s.replica_server_name,
    s.last_commit_time                          AS secondary_last_commit,
    p.last_commit_time                          AS primary_last_commit,
    DATEDIFF(SECOND, s.last_commit_time, p.last_commit_time) AS commit_skew_sec_behind_primary
FROM commits AS s
LEFT JOIN commits AS p
    ON s.ag_name = p.ag_name
   AND s.database_name = p.database_name
   AND p.is_primary_replica = 1
WHERE s.is_primary_replica = 0
ORDER BY s.ag_name, s.database_name, commit_skew_sec_behind_primary DESC;

/*──────────────────────────────────────────────────────────────────────────────
  Section 5: Quorum Votes (cluster ability to maintain majority / fail over)
──────────────────────────────────────────────────────────────────────────────*/
SELECT
    cluster_name,
    quorum_type_desc,
    quorum_state_desc
FROM sys.dm_hadr_cluster;

SELECT
    member_name                                 AS node_or_witness,
    member_type_desc                            AS member_type,
    member_state_desc                           AS member_state,
    number_of_quorum_votes                      AS quorum_votes
FROM sys.dm_hadr_cluster_members
ORDER BY member_type_desc, member_name;

/*──────────────────────────────────────────────────────────────────────────────
  Section 6: FAILOVER COMMAND TEMPLATES — COMMENTED OUT. Run deliberately only
  after confirming readiness above and obtaining authorization.
──────────────────────────────────────────────────────────────────────────────*/
/*
   -- PLANNED / no-data-loss failover (target must be SYNCHRONOUS + SYNCHRONIZED).
   -- Run on the TARGET secondary, which becomes the new primary:
   --   ALTER AVAILABILITY GROUP [YourAG] FAILOVER;

   -- FORCED failover — *** POSSIBLE DATA LOSS ***. Only when the primary is gone
   -- or the target is not synchronized. Run on the surviving secondary:
   --   ALTER AVAILABILITY GROUP [YourAG] FORCE_FAILOVER_ALLOW_DATA_LOSS;
   -- Afterward: RESUME or REMOVE+RESEED the other replicas, and reconcile lost data.
   --   ALTER DATABASE [YourDB] SET HADR RESUME;
*/
