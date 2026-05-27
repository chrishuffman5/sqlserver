/*******************************************************************************
 * SQL Server Surface-Area Check
 *
 * Purpose : Audit the dangerous surface-area configuration options, grants to
 *           the public role beyond defaults, startup stored procedures, and the
 *           linked-server inventory with its security context.
 * Version : 1.0.0
 * Targets : SQL Server 2016+ (box) and Azure SQL MI. Many sp_configure options
 *           and linked servers do not exist on Azure SQL Database.
 * Safety  : READ-ONLY. No sp_configure / RECONFIGURE is executed - remediation
 *           appears only as commented templates.
 *
 * Sections:
 *   1. Dangerous sys.configurations Options
 *   2. public Server-Level Permissions Beyond Default
 *   3. public Database-Level Permissions Beyond Default (per DB)
 *   4. Startup Stored Procedures
 *   5. Linked Servers & Security Context
 ******************************************************************************/
SET NOCOUNT ON;

/*──────────────────────────────────────────────────────────────────────────────
  Section 1: Dangerous sys.configurations Options
  Each row shows the current value and the hardened recommendation.
──────────────────────────────────────────────────────────────────────────────*/
SELECT
    c.name                                          AS configuration_option,
    c.value_in_use,
    CASE c.name
        WHEN 'xp_cmdshell'                  THEN 0
        WHEN 'Ole Automation Procedures'    THEN 0
        WHEN 'clr enabled'                  THEN 0
        WHEN 'clr strict security'          THEN 1
        WHEN 'Database Mail XPs'            THEN 0
        WHEN 'remote access'               THEN 0
        WHEN 'Ad Hoc Distributed Queries'   THEN 0
        WHEN 'cross db ownership chaining'  THEN 0
        WHEN 'remote admin connections'     THEN 0
        WHEN 'scan for startup procs'       THEN 0
    END                                             AS recommended_value,
    CASE WHEN c.value_in_use =
              CASE c.name
                WHEN 'xp_cmdshell' THEN 0 WHEN 'Ole Automation Procedures' THEN 0
                WHEN 'clr enabled' THEN 0 WHEN 'clr strict security' THEN 1
                WHEN 'Database Mail XPs' THEN 0 WHEN 'remote access' THEN 0
                WHEN 'Ad Hoc Distributed Queries' THEN 0
                WHEN 'cross db ownership chaining' THEN 0
                WHEN 'remote admin connections' THEN 0
                WHEN 'scan for startup procs' THEN 0 END
         THEN 'OK' ELSE 'REVIEW - deviates from recommendation' END AS status,
    c.description
FROM sys.configurations AS c
WHERE c.name IN ('xp_cmdshell','Ole Automation Procedures','clr enabled',
                 'clr strict security','Database Mail XPs','remote access',
                 'Ad Hoc Distributed Queries','cross db ownership chaining',
                 'remote admin connections','scan for startup procs')
ORDER BY status DESC, c.name;
-- REMEDIATION TEMPLATE (review each before running):
-- EXEC sp_configure 'show advanced options', 1; RECONFIGURE;
-- EXEC sp_configure 'xp_cmdshell', 0; RECONFIGURE;

/*──────────────────────────────────────────────────────────────────────────────
  Section 2: public Server-Level Permissions Beyond Default
  By default public has only CONNECT on endpoints + VIEW ANY DATABASE.
──────────────────────────────────────────────────────────────────────────────*/
SELECT
    perm.class_desc,
    perm.permission_name,
    perm.state_desc,
    perm.major_id
FROM sys.server_permissions AS perm
JOIN sys.server_principals  AS pr ON perm.grantee_principal_id = pr.principal_id
WHERE pr.name = 'public'
  AND NOT (perm.permission_name = 'CONNECT' AND perm.class_desc = 'ENDPOINT')
  AND perm.permission_name <> 'VIEW ANY DATABASE'
ORDER BY perm.permission_name;

/*──────────────────────────────────────────────────────────────────────────────
  Section 3: public Database-Level Permissions Beyond Default (per DB)
  Anything granted to public is granted to EVERY user - review closely.
──────────────────────────────────────────────────────────────────────────────*/
DECLARE @pub TABLE (database_name sysname, class_desc nvarchar(60),
                    permission_name nvarchar(128), state_desc nvarchar(60),
                    securable nvarchar(256));
INSERT INTO @pub
EXEC sys.sp_MSforeachdb N'
    USE [?];
    IF DB_ID() > 4 AND DATABASEPROPERTYEX(DB_NAME(),''Status'') = ''ONLINE''
    SELECT DB_NAME(), perm.class_desc, perm.permission_name, perm.state_desc,
           CASE perm.class WHEN 1
                THEN ISNULL(OBJECT_SCHEMA_NAME(perm.major_id)+''.'','''')
                   + ISNULL(OBJECT_NAME(perm.major_id),''(obj)'')
                ELSE perm.class_desc END
    FROM sys.database_permissions perm
    JOIN sys.database_principals pr ON perm.grantee_principal_id = pr.principal_id
    WHERE pr.name = ''public''
      AND NOT (perm.permission_name = ''CONNECT'' AND perm.class = 0);';
SELECT * FROM @pub
ORDER BY database_name, permission_name;

/*──────────────────────────────────────────────────────────────────────────────
  Section 4: Startup Stored Procedures (per DB; typically only in master)
──────────────────────────────────────────────────────────────────────────────*/
DECLARE @startup TABLE (database_name sysname, schema_name sysname, proc_name sysname);
INSERT INTO @startup
EXEC sys.sp_MSforeachdb N'
    USE [?];
    IF DATABASEPROPERTYEX(DB_NAME(),''Status'') = ''ONLINE''
    SELECT DB_NAME(), OBJECT_SCHEMA_NAME(object_id), name
    FROM sys.procedures
    WHERE OBJECTPROPERTY(object_id, ''ExecIsStartUp'') = 1;';
SELECT * FROM @startup ORDER BY database_name, schema_name, proc_name;
SELECT value_in_use AS scan_for_startup_procs
FROM sys.configurations WHERE name = 'scan for startup procs';

/*──────────────────────────────────────────────────────────────────────────────
  Section 5: Linked Servers & Security Context
  uses_self_credential = 1 means the mapping uses a fixed remote credential;
  review any mapping to a high-privilege remote login.
──────────────────────────────────────────────────────────────────────────────*/
SELECT
    s.name                                          AS linked_server,
    s.product,
    s.provider,
    s.data_source,
    s.is_data_access_enabled,
    s.is_rpc_out_enabled,
    ll.uses_self_credential,
    ll.remote_name                                  AS mapped_remote_login,
    CASE WHEN ll.local_principal_id = 0 THEN '(all logins)'
         ELSE SUSER_NAME(ll.local_principal_id) END AS local_login
FROM sys.servers AS s
LEFT JOIN sys.linked_logins AS ll ON s.server_id = ll.server_id
WHERE s.is_linked = 1
ORDER BY s.name, local_login;
