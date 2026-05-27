/*******************************************************************************
 * Azure SQL DB / Managed Instance - Geo-Replication & Failover Group Status
 *
 * Purpose : Report active geo-replication link state, replication lag, and
 *           failover-group readiness for an Azure SQL DB or Managed Instance.
 * Target  : Azure SQL Database (EngineEdition = 5) OR
 *           Azure SQL Managed Instance (EngineEdition = 8).
 *           These DMVs do NOT exist on the box engine (VM / RDS).
 * Safety  : Read-only. No modifications to data or configuration.
 *
 * Sections:
 *   0. Platform guard (must be Azure SQL DB = 5 or Managed Instance = 8)
 *   1. Per-database geo-replication link status & lag
 *   2. Geo-replication partner links (sys.geo_replication_links)
 *   3. Failover-group readiness summary & interpretation
 ******************************************************************************/
SET NOCOUNT ON;

DECLARE @engine INT = CONVERT(INT, SERVERPROPERTY('EngineEdition'));

/*──────────────────────────────────────────────────────────────────────────────
  Section 0: Platform guard
──────────────────────────────────────────────────────────────────────────────*/
IF @engine NOT IN (5, 8)
BEGIN
    SELECT
        'WRONG PLATFORM' AS status,
        @engine AS engine_edition,
        CONVERT(NVARCHAR(128), SERVERPROPERTY('Edition'))  AS edition,
        'This script targets Azure SQL Database (5) or Managed Instance (8). '
      + 'Geo-replication DMVs are not present on a box engine. For SQL on VM / '
      + 'AWS RDS, inspect Always On AG / Multi-AZ status with the HA tooling '
      + '(see sqlserver-ha-clustering) instead.'           AS guidance;
    RETURN;
END;

SELECT
    @engine AS engine_edition,
    CASE @engine WHEN 5 THEN 'Azure SQL Database'
                 WHEN 8 THEN 'Azure SQL Managed Instance' END AS platform,
    'Run in each database for per-DB detail (Section 1). Geo-replication is '
  + 'configured per database (SQL DB) or per instance via failover groups (MI).'
                                                              AS note;

/*──────────────────────────────────────────────────────────────────────────────
  Section 1: Per-database geo-replication link status & lag
  sys.dm_geo_replication_link_status is database-scoped: it returns rows for
  the CURRENT database's geo-replication relationships. Connect to the user
  database (not master) to see its links.
──────────────────────────────────────────────────────────────────────────────*/
IF OBJECT_ID('sys.dm_geo_replication_link_status') IS NOT NULL
BEGIN
    SELECT
        DB_NAME()                                          AS local_database,
        link_guid,
        partner_server,
        partner_database,
        role,                                              -- 0=Primary, 1=Secondary
        role_desc,
        partner_role,
        partner_role_desc,
        replication_state,                                 -- 0=Pending,1=Seeding,2=Catchup,3=Suspended
        replication_state_desc,
        secondary_allow_connections_desc,                  -- e.g. ALL (readable secondary)
        last_replication,                                  -- time of last committed txn replicated
        replication_lag_sec,                               -- async lag in seconds
        CASE
            WHEN replication_lag_sec IS NULL THEN 'No active lag metric (check state)'
            WHEN replication_lag_sec <= 5    THEN 'Healthy (<=5s)'
            WHEN replication_lag_sec <= 30   THEN 'Elevated (5-30s)'
            ELSE 'High lag (>30s) - investigate primary write rate / network'
        END                                                AS lag_assessment
    FROM sys.dm_geo_replication_link_status;

    IF @@ROWCOUNT = 0
        SELECT 'No geo-replication links found for database [' + DB_NAME() + ']. '
             + 'Either this DB has no geo-secondary, or you are connected to a DB '
             + 'without one (e.g. master). Reconnect to the replicated user DB.' AS info_message;
END
ELSE
BEGIN
    SELECT 'sys.dm_geo_replication_link_status is not available in this context.' AS info_message;
END;

/*──────────────────────────────────────────────────────────────────────────────
  Section 2: Geo-replication partner links (catalog view)
  sys.geo_replication_links lists configured links for databases on this server.
──────────────────────────────────────────────────────────────────────────────*/
IF OBJECT_ID('sys.geo_replication_links') IS NOT NULL
BEGIN
    SELECT
        DB_NAME(grl.database_id)                           AS local_database,
        grl.link_guid,
        grl.partner_server,
        grl.partner_database,
        grl.replication_state,
        grl.replication_state_desc,
        grl.role,
        grl.role_desc,
        grl.secondary_allow_connections,
        grl.secondary_allow_connections_desc,
        grl.start_date,
        grl.modify_date
    FROM sys.geo_replication_links AS grl
    ORDER BY local_database, grl.partner_server;

    IF @@ROWCOUNT = 0
        SELECT 'No rows in sys.geo_replication_links for this server context.' AS info_message;
END
ELSE
BEGIN
    SELECT 'sys.geo_replication_links is not available in this context '
         + '(query from a database that participates in geo-replication, or from master).' AS info_message;
END;

/*──────────────────────────────────────────────────────────────────────────────
  Section 3: Failover-group readiness summary & interpretation
  Failover-group config itself is exposed via ARM / portal / CLI rather than a
  single T-SQL DMV; from inside the engine we infer readiness from link state.
──────────────────────────────────────────────────────────────────────────────*/
IF OBJECT_ID('sys.dm_geo_replication_link_status') IS NOT NULL
BEGIN
    ;WITH s AS (
        SELECT
            replication_state_desc,
            replication_lag_sec,
            role_desc
        FROM sys.dm_geo_replication_link_status
    )
    SELECT
        COUNT(*)                                           AS link_count,
        SUM(CASE WHEN replication_state_desc = 'CATCH_UP' THEN 1 ELSE 0 END) AS links_caught_up,
        SUM(CASE WHEN replication_state_desc = 'SUSPENDED' THEN 1 ELSE 0 END) AS links_suspended,
        MAX(replication_lag_sec)                           AS worst_lag_sec,
        CASE
            WHEN COUNT(*) = 0 THEN 'No links - not protected by geo-replication.'
            WHEN SUM(CASE WHEN replication_state_desc = 'SUSPENDED' THEN 1 ELSE 0 END) > 0
                 THEN 'NOT READY - one or more links SUSPENDED. Resume/repair before relying on failover.'
            WHEN MAX(replication_lag_sec) > 30
                 THEN 'CAUTION - high lag; an unplanned failover may lose recent transactions.'
            ELSE 'READY - links caught up with acceptable lag. Failover-group listener will redirect clients on failover.'
        END                                                AS failover_readiness
    FROM s;
END;

/*
 * Interpretation notes:
 *  - Active geo-replication is async; an UNPLANNED (forced) failover can lose
 *    the un-replicated tail (data loss = roughly replication_lag_sec of writes).
 *    A PLANNED failover synchronizes first and is zero-loss.
 *  - A FAILOVER GROUP fronts the secondary with read-write and read-only
 *    LISTENER endpoints that follow the primary, so the app connection string
 *    does not change on failover. Raw geo-replication (no FOG) requires the app
 *    to reconnect to the secondary's own server name.
 *  - On Managed Instance, failover groups operate at INSTANCE scope (all DBs
 *    fail over together); server-level objects (logins, Agent jobs) are NOT
 *    auto-synced - script them to the secondary instance.
 */
