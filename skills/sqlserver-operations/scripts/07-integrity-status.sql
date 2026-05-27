/*******************************************************************************
 * SQL Server Operations - Integrity Status
 *
 * Purpose : Surface database integrity signals WITHOUT running intrusive checks:
 *           report suspect pages (corruption history), database state, page
 *           verify option, and document the safe ways to determine the last
 *           known good DBCC CHECKDB. This script does NOT run DBCC CHECKDB and
 *           does NOT read internal pages.
 * Version : 1.0.0
 * Targets : SQL Server 2016+ (box / Azure VM / MI / RDS).
 *           On Azure SQL DB integrity is service-managed; suspect_pages is not
 *           user-accessible the same way - guarded.
 * Safety  : READ-ONLY. Reads msdb.dbo.suspect_pages and sys.databases.
 *           No DBCC CHECKDB / DBCC PAGE / DBCC DBINFO is executed (those are
 *           intrusive and/or undocumented and are intentionally avoided).
 *
 * Sections:
 *   1. Database Page Verify & State (corruption-detection posture)
 *   2. Suspect Pages Report (corruption history from msdb)
 *   3. How To Determine Last Known Good CHECKDB (documented, not executed)
 ******************************************************************************/
SET NOCOUNT ON;

/*──────────────────────────────────────────────────────────────────────────────
  Platform guard.
──────────────────────────────────────────────────────────────────────────────*/
IF SERVERPROPERTY('EngineEdition') = 5
BEGIN
    SELECT 'Azure SQL Database: integrity checks and corruption auto-repair are '
         + 'managed by the service. msdb.dbo.suspect_pages is not user-facing here.' AS info_message;
    RETURN;
END;

/*──────────────────────────────────────────────────────────────────────────────
  Section 1: Database Page Verify & State
  PAGE_VERIFY = CHECKSUM is required for the engine to detect on-disk corruption
  (823/824). Anything other than CHECKSUM on a user DB is a risk.
──────────────────────────────────────────────────────────────────────────────*/
SELECT
    name                                                AS database_name,
    state_desc                                          AS db_state,
    page_verify_option_desc                             AS page_verify,
    recovery_model_desc,
    is_read_only,
    CASE
        WHEN database_id > 4 AND page_verify_option_desc <> 'CHECKSUM'
            THEN 'WARNING: PAGE_VERIFY is not CHECKSUM - corruption may go undetected'
        WHEN state_desc IN ('SUSPECT','EMERGENCY','RECOVERY_PENDING')
            THEN 'CRITICAL: database in ' + state_desc + ' state'
        ELSE 'ok'
    END                                                 AS assessment
FROM sys.databases
WHERE source_database_id IS NULL
ORDER BY
    CASE WHEN state_desc IN ('SUSPECT','EMERGENCY','RECOVERY_PENDING') THEN 0 ELSE 1 END,
    name;

/*──────────────────────────────────────────────────────────────────────────────
  Section 2: Suspect Pages Report (corruption history)
  event_type: 1 = 823/824 error (hardware/IO), 2 = bad checksum,
              3 = torn page, 4 = restored, 5 = repaired (DBCC),
              7 = deallocated by DBCC REPAIR_ALLOW_DATA_LOSS.
  ANY rows with event_type IN (1,2,3) indicate detected corruption - investigate.
──────────────────────────────────────────────────────────────────────────────*/
IF EXISTS (SELECT 1 FROM msdb.dbo.suspect_pages)
BEGIN
    SELECT
        DB_NAME(sp.database_id)                         AS database_name,
        sp.file_id,
        sp.page_id,
        sp.event_type,
        CASE sp.event_type
            WHEN 1 THEN '823/824 error (hardware/IO)'
            WHEN 2 THEN 'Bad checksum'
            WHEN 3 THEN 'Torn page'
            WHEN 4 THEN 'Restored (recovered)'
            WHEN 5 THEN 'Repaired by DBCC'
            WHEN 7 THEN 'Deallocated by REPAIR_ALLOW_DATA_LOSS (data lost)'
            ELSE CAST(sp.event_type AS VARCHAR(10))
        END                                             AS event_description,
        sp.error_count,
        sp.last_update_date
    FROM msdb.dbo.suspect_pages AS sp
    ORDER BY sp.last_update_date DESC;
END
ELSE
BEGIN
    SELECT 'No suspect pages recorded in msdb.dbo.suspect_pages. '
         + 'Absence is not proof of integrity - run DBCC CHECKDB on a schedule.' AS suspect_pages_status;
END;

/*──────────────────────────────────────────────────────────────────────────────
  Section 3: How To Determine Last Known Good CHECKDB (documented, NOT executed)
  ----------------------------------------------------------------------------
  SQL Server stamps the date of the last clean CHECKDB into the database boot
  page as dbi_dbccLastKnownGood. Reading it directly requires the INTRUSIVE,
  UNDOCUMENTED commands below and is therefore NOT run by this script:

      -- DBCC TRACEON (3604);
      -- DBCC PAGE ('<db>', 1, 9, 3);   -- inspect the dbi_dbccLastKnownGood field
      -- (or) DBCC DBINFO ('<db>') WITH TABLERESULTS;

  SAFE OPERATIONAL ALTERNATIVES (preferred):
    1. Run DBCC CHECKDB on a known schedule via SQL Agent / Ola Hallengren's
       DatabaseIntegrityCheck, and TREAT JOB FAILURE AS THE ALERT.
    2. Parse the SQL Server error log for the success message, e.g.:
         -- EXEC sys.sp_readerrorlog 0, 1, N'DBCC CHECKDB';
       Look for "found 0 errors and repaired 0 errors".
    3. Track CHECKDB job history in msdb.dbo.sysjobhistory (see 04-agent-jobs-health.sql).

  When corruption IS found, the decision order is:
    confirm -> check hardware/IO (823/824/825) -> RESTORE from backup
    (page restore for a few pages) -> REPAIR_ALLOW_DATA_LOSS only as last resort.
  See references/maintenance.md for the full corruption decision tree.
──────────────────────────────────────────────────────────────────────────────*/
