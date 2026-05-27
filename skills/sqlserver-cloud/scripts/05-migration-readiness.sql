/*******************************************************************************
 * On-Prem Source -> Cloud Migration Readiness Assessment
 *
 * Purpose : Inventory the things that determine cloud target feasibility and
 *           migration effort: compatibility level, deprecated-feature use,
 *           features that BLOCK Azure SQL Database specifically, database size
 *           and file count, non-default collation, and the instance-level
 *           objects that must be recreated at the target.
 * Target  : An ON-PREM (or IaaS) SOURCE box engine being assessed for the cloud.
 *           EngineEdition 2/3/4. (Run DMA for the authoritative assessment;
 *           this script gives a fast first read.)
 * Safety  : Read-only. No modifications to data or configuration.
 *
 * Sections:
 *   0. Platform guard (run against a SOURCE box engine, not a PaaS target)
 *   1. Compatibility level per database
 *   2. Deprecated / discontinued feature use (perf counters)
 *   3. Azure-SQL-DATABASE blocking features (cross-DB refs, CLR, FILESTREAM,
 *      Service Broker, Agent jobs, linked servers, server logins)
 *   4. Database size & file count
 *   5. Non-default collation (instance & databases)
 *   6. Instance-level object inventory to recreate at the target
 ******************************************************************************/
SET NOCOUNT ON;

DECLARE @engine INT = CONVERT(INT, SERVERPROPERTY('EngineEdition'));

/*──────────────────────────────────────────────────────────────────────────────
  Section 0: Platform guard
  This is a SOURCE assessment - it should run on the box engine you intend to
  migrate FROM (2/3/4). If pointed at a PaaS target, redirect the user.
──────────────────────────────────────────────────────────────────────────────*/
IF @engine NOT IN (2, 3, 4)
BEGIN
    SELECT
        'WRONG PLATFORM' AS status,
        @engine AS engine_edition,
        CONVERT(NVARCHAR(128), SERVERPROPERTY('Edition'))  AS edition,
        CASE @engine
            WHEN 5 THEN 'This is Azure SQL Database (a migration TARGET). Run this assessment against the on-prem SOURCE instead.'
            WHEN 8 THEN 'This is Azure SQL Managed Instance (a migration TARGET). Run this assessment against the on-prem SOURCE instead.'
            ELSE 'Run this against the on-prem/IaaS SOURCE box engine you intend to migrate.'
        END                                                AS guidance;
    RETURN;
END;

SELECT 'Tip: this is a fast first read. Run the Data Migration Assistant (DMA) '
     + 'for the authoritative compatibility + feature-parity report and a SKU '
     + 'recommendation for your chosen target.' AS info_message;

/*──────────────────────────────────────────────────────────────────────────────
  Section 1: Compatibility level per database
  Migrate at the source compat level, then raise it under Query Store testing.
──────────────────────────────────────────────────────────────────────────────*/
SELECT
    d.database_id,
    d.name                                                 AS database_name,
    d.compatibility_level,
    CASE
        WHEN d.compatibility_level < 130 THEN 'Below 130 - Azure targets support 100+; plan to raise after migration'
        ELSE 'Modern compat level'
    END                                                    AS compat_note,
    d.recovery_model_desc,
    d.is_read_committed_snapshot_on                        AS rcsi_on,
    d.state_desc
FROM sys.databases AS d
WHERE d.database_id > 4                                     -- skip system DBs
ORDER BY d.name;

/*──────────────────────────────────────────────────────────────────────────────
  Section 2: Deprecated / discontinued feature use (cumulative since startup)
  sys.dm_os_performance_counters 'Deprecated Features' object; non-zero counts
  flag use of features that may be removed or behave differently in the cloud.
──────────────────────────────────────────────────────────────────────────────*/
SELECT
    RTRIM(instance_name)                                   AS deprecated_feature,
    cntr_value                                             AS use_count_since_startup
FROM sys.dm_os_performance_counters
WHERE object_name LIKE '%Deprecated Features%'
  AND cntr_value > 0
ORDER BY cntr_value DESC;

IF @@ROWCOUNT = 0
    SELECT 'No deprecated-feature usage recorded since the last restart '
         + '(counters reset on restart - assess over a representative uptime).' AS info_message;

/*──────────────────────────────────────────────────────────────────────────────
  Section 3: Features that BLOCK Azure SQL Database specifically
  These are fine for MI / SQL-on-VM but must be refactored for Azure SQL DB.
──────────────────────────────────────────────────────────────────────────────*/

-- 3a. Cross-database references (3-part / cross-DB dependencies) in the CURRENT DB.
--     Run per database; cross-DB refs are the classic Azure SQL DB blocker.
SELECT
    DB_NAME()                                              AS database_name,
    OBJECT_SCHEMA_NAME(d.referencing_id)                   AS referencing_schema,
    OBJECT_NAME(d.referencing_id)                          AS referencing_object,
    d.referenced_database_name,
    d.referenced_schema_name,
    d.referenced_entity_name,
    'Cross-database reference - BLOCKS Azure SQL Database (use MI or refactor)' AS blocker
FROM sys.sql_expression_dependencies AS d
WHERE d.referenced_database_name IS NOT NULL
  AND d.referenced_database_name <> DB_NAME();

-- 3b. CLR assemblies (user) in the current DB
SELECT
    DB_NAME()                                              AS database_name,
    a.name                                                 AS assembly_name,
    a.permission_set_desc,
    'CLR assembly - not supported on Azure SQL Database' AS blocker
FROM sys.assemblies AS a
WHERE a.is_user_defined = 1;

-- 3c. FILESTREAM filegroups in the current DB
SELECT
    DB_NAME()                                              AS database_name,
    fg.name                                                AS filegroup_name,
    fg.type_desc,
    'FILESTREAM/FileTable - not supported on Azure SQL Database OR Managed Instance' AS blocker
FROM sys.filegroups AS fg
WHERE fg.type IN ('FD', 'FX');                             -- FILESTREAM / memory-optimized filestream

-- 3d. Service Broker enabled in the current DB
SELECT
    d.name                                                 AS database_name,
    d.is_broker_enabled,
    'Service Broker - not on Azure SQL DB; within-instance only on MI' AS note
FROM sys.databases AS d
WHERE d.database_id = DB_ID()
  AND d.is_broker_enabled = 1;

-- 3e. SQL Agent job count (no Agent on Azure SQL DB -> Elastic Jobs)
SELECT
    COUNT(*)                                               AS agent_job_count,
    'No SQL Agent on Azure SQL Database (re-platform to Elastic Jobs). '
  + 'MI / SQL-on-VM / RDS retain SQL Agent.'               AS note
FROM msdb.dbo.sysjobs;

-- 3f. Linked servers (not on Azure SQL DB; supported on MI / VM / RDS-via-option-group)
SELECT
    s.name                                                 AS linked_server,
    s.product,
    s.provider,
    s.data_source,
    'Linked server - not on Azure SQL DB; supported on MI / SQL-on-VM' AS note
FROM sys.servers AS s
WHERE s.server_id <> 0;                                    -- exclude the local server

/*──────────────────────────────────────────────────────────────────────────────
  Section 4: Database size & file count (drives target tier & migration method)
──────────────────────────────────────────────────────────────────────────────*/
SELECT
    DB_NAME(mf.database_id)                                AS database_name,
    SUM(CASE WHEN mf.type = 0 THEN 1 ELSE 0 END)           AS data_file_count,
    SUM(CASE WHEN mf.type = 1 THEN 1 ELSE 0 END)           AS log_file_count,
    CAST(SUM(CASE WHEN mf.type = 0 THEN mf.size END) * 8.0 / 1048576 AS DECIMAL(18,2)) AS data_size_gb,
    CAST(SUM(CASE WHEN mf.type = 1 THEN mf.size END) * 8.0 / 1048576 AS DECIMAL(18,2)) AS log_size_gb,
    CASE
        WHEN SUM(CASE WHEN mf.type = 0 THEN mf.size END) * 8.0 / 1048576 > 4096
            THEN '> 4 TB: exceeds GP/BC vCore max -> Azure SQL DB Hyperscale, MI (<=16TB), or VM'
        ELSE 'Within GP/BC vCore 4 TB limit'
    END                                                    AS size_target_hint
FROM sys.master_files AS mf
WHERE mf.database_id > 4
GROUP BY mf.database_id
ORDER BY data_size_gb DESC;

/*──────────────────────────────────────────────────────────────────────────────
  Section 5: Non-default collation (instance & databases)
  MI fixes the INSTANCE/tempdb collation at create (SQL_Latin1_General_CP1_CI_AS);
  a mismatched source instance collation is a known migration gotcha.
──────────────────────────────────────────────────────────────────────────────*/
SELECT
    CONVERT(NVARCHAR(128), SERVERPROPERTY('Collation'))    AS instance_collation,
    CASE
        WHEN CONVERT(NVARCHAR(128), SERVERPROPERTY('Collation')) <> 'SQL_Latin1_General_CP1_CI_AS'
            THEN 'Non-default instance collation - MI tempdb/instance collation is FIXED; plan for collation handling'
        ELSE 'Default instance collation - matches MI default'
    END                                                    AS collation_note;

SELECT
    d.name                                                 AS database_name,
    d.collation_name
FROM sys.databases AS d
WHERE d.database_id > 4
  AND d.collation_name <> CONVERT(NVARCHAR(128), SERVERPROPERTY('Collation'))
ORDER BY d.name;

/*──────────────────────────────────────────────────────────────────────────────
  Section 6: Instance-level object inventory to recreate at the target
  These do NOT travel with a database-level migration - recreate / remap them.
──────────────────────────────────────────────────────────────────────────────*/

-- 6a. Server-level logins (and type) - watch SID mismatches at the target
SELECT
    sp.name                                                AS login_name,
    sp.type_desc                                           AS login_type,          -- SQL_LOGIN / WINDOWS_LOGIN / WINDOWS_GROUP / etc.
    sp.is_disabled,
    sp.default_database_name,
    'Recreate at target; remap orphaned users (SID). Windows logins -> Entra ID on PaaS.' AS note
FROM sys.server_principals AS sp
WHERE sp.type IN ('S', 'U', 'G')                           -- SQL login / Windows login / Windows group
  AND sp.name NOT LIKE '##%'                               -- skip certificate-based system principals
  AND sp.name NOT LIKE 'NT %'                              -- skip built-in NT accounts
  AND sp.name NOT IN ('sa')
ORDER BY sp.type_desc, sp.name;

-- 6b. Credentials & server-scoped objects count summary
SELECT
    (SELECT COUNT(*) FROM sys.credentials)                                          AS credentials,
    (SELECT COUNT(*) FROM sys.servers WHERE server_id <> 0)                         AS linked_servers,
    (SELECT COUNT(*) FROM sys.server_triggers)                                      AS server_triggers,
    (SELECT COUNT(*) FROM msdb.dbo.sysjobs)                                         AS agent_jobs,
    (SELECT COUNT(*) FROM sys.server_principals WHERE type IN ('S','U','G')
        AND name NOT LIKE '##%' AND name NOT LIKE 'NT %')                           AS logins,
    (SELECT COUNT(*) FROM sys.certificates)                                         AS db_certificates_current_db;

-- 6c. TDE-encrypted databases (the cert must exist at the target BEFORE restore)
SELECT
    DB_NAME(dek.database_id)                               AS database_name,
    dek.encryption_state,                                  -- 3 = Encrypted
    CASE dek.encryption_state
        WHEN 0 THEN 'No key' WHEN 1 THEN 'Unencrypted' WHEN 2 THEN 'Encryption in progress'
        WHEN 3 THEN 'Encrypted' WHEN 4 THEN 'Key change in progress'
        WHEN 5 THEN 'Decryption in progress' WHEN 6 THEN 'Protection change in progress'
    END                                                    AS encryption_state_desc,
    'TDE in use - move/recreate the certificate at the target BEFORE restoring the DB' AS note
FROM sys.dm_database_encryption_keys AS dek
WHERE dek.database_id > 4;
