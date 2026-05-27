/*******************************************************************************
 * SQL Server Permissions Report
 *
 * Purpose : Enumerate granted/denied permissions and role membership at the
 *           server level and (per database) the database level, plus schema
 *           ownership. Highlights high-impact permissions (CONTROL, ALTER,
 *           IMPERSONATE, TAKE OWNERSHIP) and explicit DENY entries.
 * Version : 1.0.0
 * Targets : SQL Server 2016+ (box) and Azure SQL MI. On Azure SQL Database the
 *           server-level sections are limited; per-DB sections run.
 * Safety  : READ-ONLY. No GRANT/DENY/REVOKE or role changes are performed.
 *
 * Sections:
 *   1. Server-Level Permissions (sys.server_permissions)
 *   2. Server Role Membership (incl. user-defined server roles)
 *   3. Per-Database: Explicit Permissions
 *   4. Per-Database: Role Membership
 *   5. Per-Database: Schema Ownership
 ******************************************************************************/
SET NOCOUNT ON;

/*──────────────────────────────────────────────────────────────────────────────
  Section 1: Server-Level Permissions
  Flags high-impact permissions and explicit DENY (DENY overrides all GRANTs).
──────────────────────────────────────────────────────────────────────────────*/
SELECT
    pr.name                                         AS principal_name,
    pr.type_desc                                    AS principal_type,
    perm.class_desc,
    perm.permission_name,
    perm.state_desc                                 AS grant_state,
    CASE
        WHEN perm.state_desc = 'DENY' THEN 'DENY (overrides grants)'
        WHEN perm.permission_name IN ('CONTROL SERVER','ALTER ANY LOGIN',
             'IMPERSONATE ANY LOGIN','ALTER ANY SERVER ROLE','CONNECT SQL',
             'ALTER ANY CREDENTIAL','ALTER ANY ENDPOINT') THEN 'HIGH IMPACT'
        WHEN perm.permission_name LIKE 'IMPERSONATE%' THEN 'IMPERSONATION'
        ELSE ''
    END                                             AS note
FROM sys.server_permissions AS perm
JOIN sys.server_principals  AS pr ON perm.grantee_principal_id = pr.principal_id
WHERE pr.name NOT LIKE '##%'                         -- skip internal certs/principals
ORDER BY
    CASE WHEN perm.state_desc = 'DENY' THEN 0 ELSE 1 END,
    pr.name, perm.permission_name;

/*──────────────────────────────────────────────────────────────────────────────
  Section 2: Server Role Membership (fixed + user-defined)
──────────────────────────────────────────────────────────────────────────────*/
SELECT
    r.name                                          AS server_role,
    r.is_fixed_role,
    m.name                                          AS member,
    m.type_desc                                     AS member_type,
    m.is_disabled
FROM sys.server_role_members AS srm
JOIN sys.server_principals  AS r ON srm.role_principal_id   = r.principal_id
JOIN sys.server_principals  AS m ON srm.member_principal_id = m.principal_id
ORDER BY r.is_fixed_role DESC, r.name, m.name;

/*──────────────────────────────────────────────────────────────────────────────
  Section 3: Per-Database Explicit Permissions
  Resolves object/schema names; highlights CONTROL/ALTER/IMPERSONATE and DENY.
──────────────────────────────────────────────────────────────────────────────*/
DECLARE @perm TABLE (
    database_name sysname, principal_name sysname, principal_type nvarchar(60),
    class_desc nvarchar(60), permission_name nvarchar(128),
    state_desc nvarchar(60), securable nvarchar(256), note nvarchar(60));
INSERT INTO @perm
EXEC sys.sp_MSforeachdb N'
    USE [?];
    IF DB_ID() > 4 AND DATABASEPROPERTYEX(DB_NAME(),''Status'') = ''ONLINE''
    SELECT DB_NAME(), pr.name, pr.type_desc, perm.class_desc, perm.permission_name,
           perm.state_desc,
           CASE perm.class
                WHEN 0 THEN ''DATABASE''
                WHEN 1 THEN ISNULL(OBJECT_SCHEMA_NAME(perm.major_id)+''.'','''')
                          + ISNULL(OBJECT_NAME(perm.major_id),''(obj)'')
                WHEN 3 THEN ''SCHEMA::'' + ISNULL(SCHEMA_NAME(perm.major_id),''?'')
                ELSE perm.class_desc END,
           CASE WHEN perm.state_desc = ''DENY'' THEN ''DENY''
                WHEN perm.permission_name IN (''CONTROL'',''ALTER'',''TAKE OWNERSHIP'')
                     OR perm.permission_name LIKE ''IMPERSONATE%'' THEN ''HIGH IMPACT''
                ELSE '''' END
    FROM sys.database_permissions perm
    JOIN sys.database_principals pr ON perm.grantee_principal_id = pr.principal_id
    WHERE pr.name NOT IN (''public'') OR perm.state_desc = ''DENY'';';
SELECT * FROM @perm
ORDER BY database_name,
         CASE WHEN state_desc = 'DENY' THEN 0 ELSE 1 END,
         principal_name, permission_name;

/*──────────────────────────────────────────────────────────────────────────────
  Section 4: Per-Database Role Membership
──────────────────────────────────────────────────────────────────────────────*/
DECLARE @roles TABLE (database_name sysname, db_role sysname, is_fixed bit,
                      member sysname, member_type nvarchar(60));
INSERT INTO @roles
EXEC sys.sp_MSforeachdb N'
    USE [?];
    IF DB_ID() > 4 AND DATABASEPROPERTYEX(DB_NAME(),''Status'') = ''ONLINE''
    SELECT DB_NAME(), r.name, r.is_fixed_role, m.name, m.type_desc
    FROM sys.database_role_members drm
    JOIN sys.database_principals r ON drm.role_principal_id   = r.principal_id
    JOIN sys.database_principals m ON drm.member_principal_id = m.principal_id
    WHERE m.name <> ''dbo'';';
SELECT * FROM @roles
ORDER BY database_name, is_fixed DESC, db_role, member;

/*──────────────────────────────────────────────────────────────────────────────
  Section 5: Per-Database Schema Ownership
  Non-default schema owners can enable surprising ownership-chaining behavior.
──────────────────────────────────────────────────────────────────────────────*/
DECLARE @schemas TABLE (database_name sysname, schema_name sysname, owner_name sysname);
INSERT INTO @schemas
EXEC sys.sp_MSforeachdb N'
    USE [?];
    IF DB_ID() > 4 AND DATABASEPROPERTYEX(DB_NAME(),''Status'') = ''ONLINE''
    SELECT DB_NAME(), s.name, p.name
    FROM sys.schemas s
    JOIN sys.database_principals p ON s.principal_id = p.principal_id
    WHERE s.name NOT IN (''sys'',''INFORMATION_SCHEMA'',''guest'')
      AND s.schema_id < 16384;';                     -- exclude fixed-role schemas
SELECT * FROM @schemas
ORDER BY database_name, schema_name;
