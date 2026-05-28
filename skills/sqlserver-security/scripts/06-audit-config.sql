/*******************************************************************************
 * SQL Server Audit Configuration
 *
 * Purpose : Inventory SQL Server Audit objects - server audits, server audit
 *           specifications and their action groups, database audit
 *           specifications per database, current audit-target status, and a
 *           flag when no audits exist at all.
 * Version : 1.0.0
 * Targets : SQL Server 2016+ (box) and Azure SQL MI. Azure SQL Database uses a
 *           different (auditing-policy) model; these server-level views are for
 *           the box product / MI.
 * Safety  : READ-ONLY. No audit objects are created, enabled, or modified.
 * Note    : The per-database section uses sys.sp_MSforeachdb, which is
 *           UNDOCUMENTED and unsupported, can SILENTLY SKIP databases, and is
 *           UNAVAILABLE on Azure SQL Database. For production estates, prefer a
 *           supported explicit cursor over sys.databases (state_desc = 'ONLINE')
 *           to guarantee every database is covered.
 *
 * Sections:
 *   1. Server Audits (target, ON_FAILURE, enabled state)
 *   2. Server Audit Specifications + Action Group Details
 *   3. Database Audit Specifications + Details (per DB)
 *   4. Audit Target File Status (sys.dm_server_audit_status)
 *   5. Coverage Flag - warn if no audits are configured/enabled
 ******************************************************************************/
SET NOCOUNT ON;

/*──────────────────────────────────────────────────────────────────────────────
  Section 1: Server Audits
──────────────────────────────────────────────────────────────────────────────*/
SELECT
    sa.audit_id,
    sa.name                                         AS audit_name,
    sa.type_desc                                    AS target_type,   -- FILE / APPLICATION LOG / SECURITY LOG
    sa.on_failure_desc,                                               -- CONTINUE / SHUTDOWN / FAIL_OPERATION
    sa.is_state_enabled,
    sa.queue_delay,
    sa.max_file_size,
    sa.max_rollover_files,
    sa.create_date,
    sa.modify_date
FROM sys.server_audits AS sa
ORDER BY sa.name;

-- Optional file-target detail
SELECT
    sa.name                                         AS audit_name,
    af.log_file_path,
    af.max_file_size,
    af.max_rollover_files
FROM sys.server_file_audits AS af
JOIN sys.server_audits      AS sa ON af.audit_id = sa.audit_id
ORDER BY sa.name;

/*──────────────────────────────────────────────────────────────────────────────
  Section 2: Server Audit Specifications + Action Group Details
──────────────────────────────────────────────────────────────────────────────*/
SELECT
    sas.name                                        AS server_audit_specification,
    sa.name                                         AS bound_to_audit,
    sas.is_state_enabled,
    d.audit_action_name                             AS action_group,
    d.audited_result
FROM sys.server_audit_specifications AS sas
JOIN sys.server_audits AS sa
    ON sas.audit_guid = sa.audit_guid
LEFT JOIN sys.server_audit_specification_details AS d
    ON sas.server_specification_id = d.server_specification_id
ORDER BY sas.name, d.audit_action_name;

/*──────────────────────────────────────────────────────────────────────────────
  Section 3: Database Audit Specifications + Details (per database)
──────────────────────────────────────────────────────────────────────────────*/
DECLARE @dbaudit TABLE (
    database_name sysname, db_audit_spec sysname, is_enabled bit,
    audit_action_name nvarchar(128), class_desc nvarchar(60),
    object_name sysname NULL, principal_name sysname NULL);
INSERT INTO @dbaudit
EXEC sys.sp_MSforeachdb N'
    USE [?];
    IF DB_ID() > 4 AND DATABASEPROPERTYEX(DB_NAME(),''Status'') = ''ONLINE''
    SELECT DB_NAME(), das.name, das.is_state_enabled,
           d.audit_action_name, d.class_desc,
           CASE WHEN d.class = 1 THEN OBJECT_NAME(d.major_id) ELSE NULL END,
           USER_NAME(d.audited_principal_id)
    FROM sys.database_audit_specifications das
    LEFT JOIN sys.database_audit_specification_details d
        ON das.database_specification_id = d.database_specification_id;';
SELECT * FROM @dbaudit
ORDER BY database_name, db_audit_spec, audit_action_name;

/*──────────────────────────────────────────────────────────────────────────────
  Section 4: Audit Target File Status (running audits + current file path)
──────────────────────────────────────────────────────────────────────────────*/
SELECT
    status.audit_id,
    sa.name                                         AS audit_name,
    status.status_desc,
    status.audit_file_path,
    status.audit_file_size
FROM sys.dm_server_audit_status AS status
JOIN sys.server_audits AS sa ON status.audit_id = sa.audit_id
ORDER BY sa.name;

/*──────────────────────────────────────────────────────────────────────────────
  Section 5: Coverage Flag - warn if no audits configured / enabled
──────────────────────────────────────────────────────────────────────────────*/
SELECT
    (SELECT COUNT(*) FROM sys.server_audits)                                AS total_audits,
    (SELECT COUNT(*) FROM sys.server_audits WHERE is_state_enabled = 1)     AS enabled_audits,
    (SELECT COUNT(*) FROM sys.server_audit_specifications
                     WHERE is_state_enabled = 1)                            AS enabled_server_specs,
    CASE
        WHEN NOT EXISTS (SELECT 1 FROM sys.server_audits)
            THEN 'NO SQL Server Audit configured - no auditing in place.'
        WHEN NOT EXISTS (SELECT 1 FROM sys.server_audits WHERE is_state_enabled = 1)
            THEN 'Audit(s) exist but NONE are enabled.'
        ELSE 'At least one audit is enabled (verify it captures login/permission events).'
    END                                                                     AS coverage_assessment;
-- SETUP TEMPLATE (review before running): see references/hardening-and-auditing.md
-- CREATE SERVER AUDIT [SecAudit] TO FILE (FILEPATH = N'D:\Audit\')
--   WITH (ON_FAILURE = CONTINUE);
-- ALTER SERVER AUDIT [SecAudit] WITH (STATE = ON);
