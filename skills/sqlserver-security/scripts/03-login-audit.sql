/*******************************************************************************
 * SQL Server Login Audit
 *
 * Purpose : Review the login-audit configuration, extract failed-login (error
 *           18456) events from the error log with a state-code legend, snapshot
 *           current sessions/connections, and list disabled or recently changed
 *           logins.
 * Version : 1.0.0
 * Targets : SQL Server 2016+ (box) and Azure SQL MI. xp_readerrorlog and the
 *           AuditLevel registry read are NOT available on Azure SQL Database.
 * Safety  : READ-ONLY. Reads the error log and DMVs only; no changes.
 *
 * Sections:
 *   1. Login Audit Level (registry) + Authentication Mode
 *   2. Error 18456 State-Code Legend (reference)
 *   3. Failed Logins from the Error Log (xp_readerrorlog)
 *   4. Current Session / Connection Snapshot (auth scheme, encryption)
 *   5. Logins: Disabled and Last-Modified
 ******************************************************************************/
SET NOCOUNT ON;

/*──────────────────────────────────────────────────────────────────────────────
  Section 1: Login Audit Level + Authentication Mode
  AuditLevel: 0 = none, 1 = successful, 2 = failed, 3 = both.
  (Registry read; not available on Azure SQL Database.)
──────────────────────────────────────────────────────────────────────────────*/
BEGIN TRY
    DECLARE @auditlevel INT;
    EXEC master.dbo.xp_instance_regread
        N'HKEY_LOCAL_MACHINE',
        N'Software\Microsoft\MSSQLServer\MSSQLServer',
        N'AuditLevel', @auditlevel OUTPUT;
    SELECT
        @auditlevel                                 AS login_audit_level,
        CASE @auditlevel WHEN 0 THEN 'None'
                         WHEN 1 THEN 'Successful logins only'
                         WHEN 2 THEN 'Failed logins only (minimum recommended)'
                         WHEN 3 THEN 'Both successful and failed (recommended)'
                         ELSE 'Unknown' END          AS audit_level_description,
        SERVERPROPERTY('IsIntegratedSecurityOnly')   AS is_windows_auth_only;
END TRY
BEGIN CATCH
    SELECT 'Could not read AuditLevel (Azure SQL DB or restricted permissions).' AS info_message;
END CATCH;

/*──────────────────────────────────────────────────────────────────────────────
  Section 2: Error 18456 State-Code Legend (reference only - see authentication.md)
   2/5  : login does not exist
   6    : Windows/SQL login type mismatch
   7    : login disabled AND password mismatch
   8    : password mismatch
   9    : password not valid
   11/12: login valid but server access denied (often Kerberos/SPN/permission)
   18   : password expired / must change
   38/40: cannot open the default/target database (no access)
   58   : SQL login used while server is in Windows-only mode
   102+ : Entra ID / Azure AD authentication failures
──────────────────────────────────────────────────────────────────────────────*/

/*──────────────────────────────────────────────────────────────────────────────
  Section 3: Failed Logins from the Error Log (current + previous log)
  Captures lines containing 'Login failed'; the state code is in the text.
──────────────────────────────────────────────────────────────────────────────*/
BEGIN TRY
    DECLARE @errlog TABLE (LogDate datetime, ProcessInfo nvarchar(100), [Text] nvarchar(4000));
    INSERT INTO @errlog EXEC master.dbo.xp_readerrorlog 0, 1, N'Login failed';
    INSERT INTO @errlog EXEC master.dbo.xp_readerrorlog 1, 1, N'Login failed';

    SELECT TOP (200)
        LogDate,
        [Text]                                      AS failed_login_message,
        -- best-effort state extraction for quick triage
        SUBSTRING([Text],
                  NULLIF(CHARINDEX('State:', [Text]),0)+6, 6) AS state_hint
    FROM @errlog
    ORDER BY LogDate DESC;

    -- Summary by message (collapses repeated attempts)
    SELECT [Text] AS failed_login_message, COUNT(*) AS occurrences,
           MIN(LogDate) AS first_seen, MAX(LogDate) AS last_seen
    FROM @errlog
    GROUP BY [Text]
    ORDER BY occurrences DESC;
END TRY
BEGIN CATCH
    SELECT 'xp_readerrorlog unavailable (Azure SQL DB) - use sys.event_log / Audit instead.' AS info_message;
END CATCH;

/*──────────────────────────────────────────────────────────────────────────────
  Section 4: Current Session / Connection Snapshot
  Point-in-time view: who is connected, with which auth scheme & encryption.
──────────────────────────────────────────────────────────────────────────────*/
SELECT
    s.session_id,
    s.login_name,
    s.original_login_name,
    s.host_name,
    s.program_name,
    c.auth_scheme,                                  -- KERBEROS / NTLM / SQL / DIGEST
    c.net_transport,
    c.encrypt_option                               AS connection_encrypted,
    s.login_time,
    s.last_request_start_time,
    s.is_user_process
FROM sys.dm_exec_sessions AS s
LEFT JOIN sys.dm_exec_connections AS c ON s.session_id = c.session_id
WHERE s.is_user_process = 1
ORDER BY s.login_time DESC;

-- Aggregate logins by auth scheme + encryption (spot unencrypted / NTLM sessions)
SELECT c.auth_scheme, c.encrypt_option AS encrypted, COUNT(*) AS sessions
FROM sys.dm_exec_connections AS c
JOIN sys.dm_exec_sessions    AS s ON c.session_id = s.session_id
WHERE s.is_user_process = 1
GROUP BY c.auth_scheme, c.encrypt_option
ORDER BY sessions DESC;

/*──────────────────────────────────────────────────────────────────────────────
  Section 5: Logins - Disabled and Last-Modified
──────────────────────────────────────────────────────────────────────────────*/
SELECT
    name                                            AS login_name,
    type_desc,
    is_disabled,
    create_date,
    modify_date,
    DATEDIFF(DAY, modify_date, SYSUTCDATETIME())    AS days_since_modified
FROM sys.server_principals
WHERE type IN ('S','U','G','C','K','E','X')          -- actual logins, not roles
ORDER BY is_disabled DESC, modify_date DESC;
