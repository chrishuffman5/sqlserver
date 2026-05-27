/*******************************************************************************
 * SQL Server Operations - SQL Agent Jobs Health
 *
 * Purpose : Inventory SQL Agent jobs and their health: enabled/disabled state,
 *           last run outcome, failed jobs, currently running and long-running
 *           jobs, schedules, and jobs owned by sysadmins.
 * Version : 1.0.0
 * Targets : SQL Server 2016+ (box / Azure VM / Managed Instance / RDS).
 *           Azure SQL Database has NO SQL Agent (use Elastic Jobs) - guarded.
 *           Express edition has NO Agent.
 * Safety  : READ-ONLY. Reads msdb Agent metadata/history only. No job is
 *           started, stopped, enabled, or modified.
 *
 * Sections:
 *   1. Job Inventory (owner, enabled, category, last/next run)
 *   2. Last Run Outcome & Failed Jobs
 *   3. Currently Running / Long-Running Jobs
 *   4. Job Schedules
 *   5. Jobs Owned By sysadmins (security note)
 ******************************************************************************/
SET NOCOUNT ON;

/*──────────────────────────────────────────────────────────────────────────────
  Platform guard: Azure SQL Database has no SQL Agent.
──────────────────────────────────────────────────────────────────────────────*/
IF SERVERPROPERTY('EngineEdition') = 5
BEGIN
    SELECT 'Azure SQL Database has no SQL Agent. Use Elastic Jobs '
         + '(jobs.* procedures in the job database) for scheduling.' AS info_message;
    RETURN;
END;

/*──────────────────────────────────────────────────────────────────────────────
  Section 1: Job Inventory
  msdb.dbo.agent_datetime() converts the integer run_date/run_time columns.
──────────────────────────────────────────────────────────────────────────────*/
SELECT
    j.name                                              AS job_name,
    SUSER_SNAME(j.owner_sid)                            AS job_owner,
    j.enabled,
    c.name                                              AS category,
    ja.run_requested_date                               AS last_start_requested,
    ja.next_scheduled_run_date,
    j.date_created,
    j.date_modified
FROM msdb.dbo.sysjobs AS j
LEFT JOIN msdb.dbo.syscategories AS c
    ON j.category_id = c.category_id
OUTER APPLY (
    SELECT TOP (1) a.run_requested_date, a.next_scheduled_run_date
    FROM msdb.dbo.sysjobactivity a
    WHERE a.job_id = j.job_id
    ORDER BY a.session_id DESC
) AS ja
ORDER BY j.enabled DESC, j.name;

/*──────────────────────────────────────────────────────────────────────────────
  Section 2: Last Run Outcome & Failed Jobs
  run_status: 0=Failed, 1=Succeeded, 2=Retry, 3=Canceled, 4=In Progress.
  step_id = 0 is the job outcome (overall), not an individual step.
──────────────────────────────────────────────────────────────────────────────*/
;WITH last_outcome AS (
    SELECT
        h.job_id,
        h.run_status,
        h.run_date, h.run_time,
        h.run_duration,
        h.message,
        ROW_NUMBER() OVER (PARTITION BY h.job_id
                           ORDER BY h.run_date DESC, h.run_time DESC) AS rn
    FROM msdb.dbo.sysjobhistory h
    WHERE h.step_id = 0
)
SELECT
    j.name                                              AS job_name,
    j.enabled,
    CASE lo.run_status
        WHEN 0 THEN 'FAILED'
        WHEN 1 THEN 'Succeeded'
        WHEN 2 THEN 'Retry'
        WHEN 3 THEN 'Canceled'
        WHEN 4 THEN 'In Progress'
        ELSE 'Unknown'
    END                                                 AS last_outcome,
    msdb.dbo.agent_datetime(lo.run_date, lo.run_time)   AS last_run_datetime,
    -- run_duration is HHMMSS as an integer; convert to seconds
    (lo.run_duration / 10000) * 3600
        + ((lo.run_duration / 100) % 100) * 60
        + (lo.run_duration % 100)                       AS last_duration_seconds,
    lo.message                                          AS last_message
FROM msdb.dbo.sysjobs j
LEFT JOIN last_outcome lo ON j.job_id = lo.job_id AND lo.rn = 1
ORDER BY CASE WHEN lo.run_status = 0 THEN 0 ELSE 1 END, j.name;

/*──────────────────────────────────────────────────────────────────────────────
  Section 3: Currently Running / Long-Running Jobs
  A job is running when it has a start_execution_date and no stop_execution_date
  for the most recent session.
──────────────────────────────────────────────────────────────────────────────*/
;WITH running AS (
    SELECT
        ja.job_id,
        ja.start_execution_date,
        ROW_NUMBER() OVER (PARTITION BY ja.job_id ORDER BY ja.session_id DESC) AS rn,
        ja.stop_execution_date
    FROM msdb.dbo.sysjobactivity ja
)
SELECT
    j.name                                              AS job_name,
    r.start_execution_date,
    DATEDIFF(SECOND, r.start_execution_date, GETDATE()) AS running_seconds
FROM running r
JOIN msdb.dbo.sysjobs j ON r.job_id = j.job_id
WHERE r.rn = 1
  AND r.start_execution_date IS NOT NULL
  AND r.stop_execution_date IS NULL
ORDER BY running_seconds DESC;

/*──────────────────────────────────────────────────────────────────────────────
  Section 4: Job Schedules
──────────────────────────────────────────────────────────────────────────────*/
SELECT
    j.name                                              AS job_name,
    s.name                                              AS schedule_name,
    s.enabled                                           AS schedule_enabled,
    CASE s.freq_type
        WHEN 1  THEN 'One time'
        WHEN 4  THEN 'Daily'
        WHEN 8  THEN 'Weekly'
        WHEN 16 THEN 'Monthly'
        WHEN 32 THEN 'Monthly relative'
        WHEN 64 THEN 'On Agent start'
        WHEN 128 THEN 'On CPU idle'
        ELSE CAST(s.freq_type AS VARCHAR(10))
    END                                                 AS frequency,
    s.freq_subday_interval                              AS subday_interval,
    CASE s.freq_subday_type
        WHEN 1 THEN 'At specified time'
        WHEN 2 THEN 'Seconds'
        WHEN 4 THEN 'Minutes'
        WHEN 8 THEN 'Hours'
        ELSE CAST(s.freq_subday_type AS VARCHAR(10))
    END                                                 AS subday_unit,
    s.active_start_time                                 AS active_start_time_hhmmss
FROM msdb.dbo.sysjobs j
JOIN msdb.dbo.sysjobschedules js ON j.job_id = js.job_id
JOIN msdb.dbo.sysschedules s     ON js.schedule_id = s.schedule_id
ORDER BY j.name, s.name;

/*──────────────────────────────────────────────────────────────────────────────
  Section 5: Jobs Owned By sysadmins (security note)
  Jobs owned by a sysadmin login run with elevated rights. Prefer a dedicated
  low-privilege service login as owner where possible.
──────────────────────────────────────────────────────────────────────────────*/
SELECT
    j.name                                              AS job_name,
    SUSER_SNAME(j.owner_sid)                            AS job_owner,
    'Owner is a member of sysadmin - review least-privilege ownership' AS note
FROM msdb.dbo.sysjobs j
WHERE IS_SRVROLEMEMBER('sysadmin', SUSER_SNAME(j.owner_sid)) = 1
ORDER BY j.name;

/*──────────────────────────────────────────────────────────────────────────────
  RECOMMENDATION TEMPLATES (commented out — review before running):

  -- Wire failure notification on a job (requires an operator + Database Mail):
  -- EXEC msdb.dbo.sp_update_job @job_name = N'<job>',
  --      @notify_level_email = 2, @notify_email_operator_name = N'DBA Team';

  -- Reassign job ownership to a low-privilege login:
  -- EXEC msdb.dbo.sp_update_job @job_name = N'<job>', @owner_login_name = N'svc-sqljobs';
──────────────────────────────────────────────────────────────────────────────*/
