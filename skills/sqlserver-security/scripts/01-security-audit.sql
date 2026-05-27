/*******************************************************************************
 * SQL Server Security Audit - Overview
 *
 * Purpose : High-level security posture review: authentication mode, high-
 *           privilege role membership, the sa account, weak/misconfigured SQL
 *           logins, enabled guest users, and orphaned database users.
 * Version : 1.0.0
 * Targets : SQL Server 2016+ (box) and Azure SQL MI. On Azure SQL Database
 *           some server-level objects are unavailable; per-DB sections still run.
 * Safety  : READ-ONLY. No data, login, permission, or configuration changes.
 *           All remediation is shown ONLY as commented-out templates.
 *
 * Sections:
 *   1. Authentication Mode
 *   2. sysadmin / securityadmin Membership (high-risk)
 *   3. sa Account Status
 *   4. SQL Logins Missing CHECK_POLICY / CHECK_EXPIRATION
 *   5. Weak / Blank Password Probe (OPTIONAL - commented)
 *   6. guest User Enabled Per Database
 *   7. Orphaned Database Users (no matching login by SID)
 *   8. High-Privilege Role Membership Summary (server + fixed db roles)
 ******************************************************************************/
SET NOCOUNT ON;

/*──────────────────────────────────────────────────────────────────────────────
  Section 1: Authentication Mode
  1 = Windows Authentication only; 0 = Mixed Mode (Windows + SQL).
──────────────────────────────────────────────────────────────────────────────*/
SELECT
    SERVERPROPERTY('IsIntegratedSecurityOnly')      AS is_windows_auth_only,
    CASE SERVERPROPERTY('IsIntegratedSecurityOnly')
        WHEN 1 THEN 'Windows Authentication only (more secure)'
        WHEN 0 THEN 'Mixed Mode (Windows + SQL) - ensure SQL logins are hardened'
        ELSE 'Unknown / not applicable (Azure SQL DB)'
    END                                             AS auth_mode_description,
    SERVERPROPERTY('MachineName')                   AS machine_name,
    SERVERPROPERTY('ProductVersion')                AS product_version,
    SERVERPROPERTY('Edition')                       AS edition;

/*──────────────────────────────────────────────────────────────────────────────
  Section 2: sysadmin / securityadmin Membership (high-risk)
  securityadmin can GRANT itself any permission - treat it as sysadmin-equivalent.
──────────────────────────────────────────────────────────────────────────────*/
SELECT
    sr.name                                         AS server_role,
    sp.name                                         AS member_login,
    sp.type_desc                                    AS member_type,
    sp.is_disabled,
    sp.create_date,
    sp.modify_date
FROM sys.server_role_members AS srm
JOIN sys.server_principals  AS sr ON srm.role_principal_id   = sr.principal_id
JOIN sys.server_principals  AS sp ON srm.member_principal_id = sp.principal_id
WHERE sr.name IN ('sysadmin', 'securityadmin')
ORDER BY sr.name, sp.name;

/*──────────────────────────────────────────────────────────────────────────────
  Section 3: sa Account Status
  Matched by well-known SID (0x01) so a renamed sa is still found.
──────────────────────────────────────────────────────────────────────────────*/
SELECT
    name                                            AS sa_login_name,
    is_disabled,
    CASE WHEN is_disabled = 1 THEN 'Disabled (good)'
         ELSE 'ENABLED - consider disabling/renaming' END AS recommendation,
    modify_date
FROM sys.server_principals
WHERE sid = 0x01;
-- REMEDIATION TEMPLATE (review first):
-- ALTER LOGIN [sa] DISABLE;
-- ALTER LOGIN [sa] WITH NAME = [disabled_sa];

/*──────────────────────────────────────────────────────────────────────────────
  Section 4: SQL Logins Missing CHECK_POLICY / CHECK_EXPIRATION
  CHECK_POLICY should be ON. CHECK_EXPIRATION typically OFF for service accounts.
──────────────────────────────────────────────────────────────────────────────*/
SELECT
    sl.name                                         AS sql_login,
    sl.is_disabled,
    sl.is_policy_checked                            AS check_policy_on,
    sl.is_expiration_checked                        AS check_expiration_on,
    LOGINPROPERTY(sl.name, 'PasswordLastSetTime')   AS password_last_set,
    LOGINPROPERTY(sl.name, 'IsLocked')              AS is_locked_out,
    LOGINPROPERTY(sl.name, 'BadPasswordCount')      AS bad_password_count
FROM sys.sql_logins AS sl
WHERE sl.is_disabled = 0
  AND (sl.is_policy_checked = 0 OR sl.is_expiration_checked = 0)
ORDER BY sl.is_policy_checked, sl.name;
-- REMEDIATION TEMPLATE:
-- ALTER LOGIN [the_login] WITH CHECK_POLICY = ON;

/*──────────────────────────────────────────────────────────────────────────────
  Section 5: Weak / Blank Password Probe (OPTIONAL)
  PWDCOMPARE is read-only but probing every login can be intrusive; uncomment
  deliberately. Extend the common-password list to taste.
──────────────────────────────────────────────────────────────────────────────*/
-- SELECT sl.name AS sql_login, 'matched a weak/blank password' AS finding
-- FROM sys.sql_logins AS sl
-- CROSS APPLY (VALUES ('') , ('password') , ('Password1') , ('sa')
--                   , (sl.name) , ('P@ssw0rd') , ('123456')) AS w(pwd)
-- WHERE sl.is_disabled = 0
--   AND PWDCOMPARE(w.pwd, sl.password_hash) = 1;

/*──────────────────────────────────────────────────────────────────────────────
  Section 6: guest User Enabled Per Database
  guest should be disabled (REVOKE CONNECT) in user databases.
──────────────────────────────────────────────────────────────────────────────*/
DECLARE @guest TABLE (database_name sysname, guest_has_connect bit);
INSERT INTO @guest (database_name, guest_has_connect)
EXEC sys.sp_MSforeachdb N'
    USE [?];
    IF DB_ID() > 4 AND DATABASEPROPERTYEX(DB_NAME(),''Status'') = ''ONLINE''
    SELECT DB_NAME(),
           CASE WHEN EXISTS (
               SELECT 1 FROM sys.database_permissions dp
               JOIN sys.database_principals pr ON dp.grantee_principal_id = pr.principal_id
               WHERE pr.name = ''guest'' AND dp.permission_name = ''CONNECT''
                 AND dp.state_desc = ''GRANT'') THEN 1 ELSE 0 END;';
SELECT database_name,
       guest_has_connect,
       CASE WHEN guest_has_connect = 1
            THEN 'guest can CONNECT - consider REVOKE CONNECT FROM guest;'
            ELSE 'guest disabled (good)' END        AS recommendation
FROM @guest
ORDER BY guest_has_connect DESC, database_name;

/*──────────────────────────────────────────────────────────────────────────────
  Section 7: Orphaned Database Users (no matching server login by SID)
  Excludes roles, fixed/system principals, and contained/Entra users by type.
──────────────────────────────────────────────────────────────────────────────*/
DECLARE @orphans TABLE (database_name sysname, user_name sysname,
                        type_desc nvarchar(60), auth_type nvarchar(60));
INSERT INTO @orphans
EXEC sys.sp_MSforeachdb N'
    USE [?];
    IF DB_ID() > 4 AND DATABASEPROPERTYEX(DB_NAME(),''Status'') = ''ONLINE''
    SELECT DB_NAME(), dp.name, dp.type_desc, dp.authentication_type_desc
    FROM sys.database_principals dp
    WHERE dp.type IN (''S'',''U'',''G'')              -- SQL / Windows user / group
      AND dp.authentication_type = 1                   -- INSTANCE (login-mapped) only
      AND dp.sid IS NOT NULL
      AND dp.name NOT IN (''dbo'',''guest'',''sys'',''INFORMATION_SCHEMA'')
      AND NOT EXISTS (SELECT 1 FROM sys.server_principals sp WHERE sp.sid = dp.sid);';
SELECT database_name, user_name, type_desc, auth_type,
       'Orphaned: no login matches this user''s SID' AS finding
FROM @orphans
ORDER BY database_name, user_name;
-- REMEDIATION TEMPLATE (per DB): ALTER USER [u] WITH LOGIN = [matching_login];

/*──────────────────────────────────────────────────────────────────────────────
  Section 8: High-Privilege Role Membership Summary (server-level)
  STRING_AGG requires SQL Server 2017+. On SQL Server 2016 use the commented
  FOR XML PATH fallback below instead.
──────────────────────────────────────────────────────────────────────────────*/
-- SQL Server 2017+ (STRING_AGG):
SELECT
    sr.name                                         AS server_role,
    COUNT(sp.principal_id)                          AS member_count,
    STRING_AGG(sp.name, ', ')                        AS members
FROM sys.server_principals AS sr
LEFT JOIN sys.server_role_members AS srm ON sr.principal_id = srm.role_principal_id
LEFT JOIN sys.server_principals   AS sp  ON srm.member_principal_id = sp.principal_id
WHERE sr.type = 'R' AND sr.is_fixed_role = 1
GROUP BY sr.name
ORDER BY sr.name;

-- SQL Server 2016 fallback (FOR XML PATH concatenation):
-- SELECT sr.name AS server_role,
--        (SELECT COUNT(*) FROM sys.server_role_members m
--         WHERE m.role_principal_id = sr.principal_id) AS member_count,
--        STUFF((SELECT ', ' + sp.name
--               FROM sys.server_role_members srm
--               JOIN sys.server_principals sp ON srm.member_principal_id = sp.principal_id
--               WHERE srm.role_principal_id = sr.principal_id
--               FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, '') AS members
-- FROM sys.server_principals sr
-- WHERE sr.type = 'R' AND sr.is_fixed_role = 1
-- ORDER BY sr.name;
