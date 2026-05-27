# SQL Agent, Alerts, and Database Mail Reference

SQL Server Agent is the scheduling and automation service for the box product, Azure VM, Managed Instance, and (with constraints) AWS RDS. It runs jobs on schedules, raises and responds to alerts, and notifies operators via Database Mail. This reference covers the architecture, creating objects in T-SQL, failure handling, Database Mail, alerting, multiserver administration, and the per-platform availability matrix — including the **Elastic Jobs** alternative for Azure SQL Database (which has no Agent).

## Agent Availability by Platform

| Platform | SQL Agent | Notes |
|---|---|---|
| Box (Windows/Linux) Enterprise/Standard/Developer | **Yes** | Full feature set. On Linux, Agent is included but a few features (some replication agents) differ. |
| **Express edition** | **No** | No Agent at all. Use Windows Task Scheduler + `sqlcmd`, or upgrade edition. |
| **SQL on Azure VM (IaaS)** | **Yes** | Same as box; you own it. |
| **Azure SQL Managed Instance** | **Yes** | Agent is present (jobs, schedules, operators, Database Mail). A few job subsystems differ; no `xp_cmdshell`. |
| **Azure SQL Database** | **No** | Use **Elastic Jobs** (elastic job agent) instead — see the dedicated section below. |
| **AWS RDS for SQL Server** | **Yes (constrained)** | Agent runs, but no `sa`, limited sysadmin, no direct OS access, no `xp_cmdshell`; some steps must use `rdsadmin` procedures. |

## Agent Architecture

```
SQL Server Agent service
├── Jobs            — a named unit of work
│   ├── Steps       — ordered actions (T-SQL, OS cmd, PowerShell, SSIS, replication…)
│   │               with on-success / on-failure flow control and per-step retries
│   ├── Schedules   — when the job runs (recurring, one-time, on Agent start, on CPU idle)
│   └── Notifications — email/page/event-log on success/failure/completion
├── Operators       — notification recipients (name + email address / pager)
├── Alerts          — respond to error severities, message IDs, performance conditions, or WMI events
├── Proxies         — run non-T-SQL steps under a specific credential (least privilege)
└── Database Mail   — SMTP-based mail subsystem used for notifications
```

Agent metadata lives in **`msdb`** (`sysjobs`, `sysjobsteps`, `sysjobschedules`, `sysjobhistory`, `sysoperators`, `sysalerts`, etc.). The Agent service account needs appropriate rights; non-sysadmins use the `SQLAgentUserRole`/`SQLAgentReaderRole`/`SQLAgentOperatorRole` roles in msdb.

## Creating a Job in T-SQL

```sql
USE msdb;

-- 1) The job (owned by a low-privilege login, NOT a person)
EXEC dbo.sp_add_job
    @job_name        = N'Nightly Log Backups',
    @owner_login_name = N'sa',          -- or a dedicated service login
    @description     = N'Backs up transaction logs for user databases.';

-- 2) A T-SQL step
EXEC dbo.sp_add_jobstep
    @job_name   = N'Nightly Log Backups',
    @step_name  = N'Backup logs',
    @subsystem  = N'TSQL',
    @database_name = N'master',
    @command    = N'EXEC dbo.DatabaseBackup @Databases=''USER_DATABASES'', @BackupType=''LOG'', @Compress=''Y'', @Verify=''Y'';',
    @retry_attempts = 2,
    @retry_interval = 5,                -- minutes
    @on_success_action = 1,             -- 1=quit success, 3=next step, 4=goto step
    @on_fail_action    = 2;             -- 2=quit with failure

-- 3) A schedule (every 15 minutes, all day)
EXEC dbo.sp_add_schedule
    @schedule_name = N'Every 15 min',
    @freq_type = 4,                     -- daily
    @freq_interval = 1,
    @freq_subday_type = 4,              -- minutes
    @freq_subday_interval = 15,
    @active_start_time = 000000;

EXEC dbo.sp_attach_schedule @job_name = N'Nightly Log Backups', @schedule_name = N'Every 15 min';

-- 4) Register the job with the local server so Agent runs it
EXEC dbo.sp_add_jobserver @job_name = N'Nightly Log Backups';

-- 5) Wire failure notification (see Operators below)
EXEC dbo.sp_update_job
    @job_name = N'Nightly Log Backups',
    @notify_level_email = 2,            -- 1=success, 2=failure, 3=completion
    @notify_email_operator_name = N'DBA Team';
```

Useful management procs: `sp_start_job`, `sp_stop_job`, `sp_update_jobstep`, `sp_delete_job`, and `sp_help_job` / `sp_help_jobhistory` for inspection.

## Job Failure Handling and Retries

- **Per-step retries** (`@retry_attempts`, `@retry_interval`) handle transient errors (e.g., a briefly locked resource). Don't set huge retry counts on a step that fails deterministically.
- **Flow control** (`@on_success_action` / `@on_fail_action`) lets a job, for example, run a cleanup step even when the main step fails (goto a step), or quit immediately on failure.
- **Always notify on failure.** A job that fails silently is the root of many outages. Set `@notify_level_email = 2` (failure) at minimum, pointing at an operator that the on-call DBA monitors.
- **Inspect failures:**

  ```sql
  -- Recent failed job runs
  SELECT j.name AS job_name, h.step_id, h.step_name,
         msdb.dbo.agent_datetime(h.run_date, h.run_time) AS run_datetime,
         h.run_status,   -- 0=failed,1=succeeded,2=retry,3=canceled,4=in progress
         h.message
  FROM msdb.dbo.sysjobhistory h
  JOIN msdb.dbo.sysjobs j ON h.job_id = j.job_id
  WHERE h.run_status = 0
  ORDER BY h.run_date DESC, h.run_time DESC;
  ```

## Proxies and Credentials

Non-T-SQL steps (CmdExec, PowerShell, SSIS) run under the Agent service account by default. To follow least privilege, create a **credential** (mapped to a Windows/domain account) and a **proxy** for that subsystem, then run the step as the proxy. This avoids giving the Agent service account broad OS rights.

```sql
-- Credential (server level) → Proxy (Agent) → assign to subsystem
CREATE CREDENTIAL [BackupFileCred] WITH IDENTITY = N'DOMAIN\svc-sqlbackup', SECRET = N'***';
EXEC msdb.dbo.sp_add_proxy @proxy_name = N'BackupFileProxy', @credential_name = N'BackupFileCred', @enabled = 1;
EXEC msdb.dbo.sp_grant_proxy_to_subsystem @proxy_name = N'BackupFileProxy', @subsystem_id = 11; -- 11 = PowerShell
```

## Database Mail

Database Mail is the SMTP-based notification transport. Set up a **profile** containing one or more **accounts** (SMTP server, port, credentials), then enable Agent to use it.

```sql
-- 1) Enable Database Mail XPs
EXEC sp_configure 'show advanced options', 1; RECONFIGURE;
EXEC sp_configure 'Database Mail XPs', 1;     RECONFIGURE;

-- 2) Account + profile
EXEC msdb.dbo.sysmail_add_account_sp
    @account_name = N'DBA Mail Account',
    @email_address = N'sqlalerts@contoso.com',
    @display_name = N'SQL Server Alerts',
    @mailserver_name = N'smtp.contoso.com', @port = 587;
EXEC msdb.dbo.sysmail_add_profile_sp @profile_name = N'DBA Mail Profile';
EXEC msdb.dbo.sysmail_add_profileaccount_sp
    @profile_name = N'DBA Mail Profile', @account_name = N'DBA Mail Account', @sequence_number = 1;

-- 3) Tell Agent to use Database Mail and the profile
EXEC msdb.dbo.sp_set_sqlagent_properties @email_save_in_sent_folder = 1;
-- (Set the Agent mail profile via Agent Properties / Alert System, or sp_set_sqlagent_properties depending on version.)

-- 4) Test
EXEC msdb.dbo.sp_send_dbmail
    @profile_name = N'DBA Mail Profile',
    @recipients = N'dba-team@contoso.com',
    @subject = N'Database Mail test',
    @body = N'If you can read this, Database Mail works.';
```

Troubleshoot with `msdb.dbo.sysmail_event_log` and `sysmail_allitems` / `sysmail_faileditems`.

> **Platform note:** **Managed Instance** supports Database Mail. **Azure SQL Database** does **not** — use Azure Logic Apps, Azure Automation, or Action Groups for notifications, and Elastic Jobs for scheduling. **RDS** supports Database Mail but configuration is via the RDS option/parameter mechanisms in places.

## Operators

```sql
EXEC msdb.dbo.sp_add_operator
    @name = N'DBA Team',
    @enabled = 1,
    @email_address = N'dba-team@contoso.com';
-- Designate a fail-safe operator (notified if the normal operator can't be reached)
```

A **fail-safe operator** (set in Agent Alert System properties) is notified when alerting can't reach the intended operator — configure one so critical alerts are never dropped.

## Alerts

Alerts let Agent react automatically to engine events. Three kinds:

### 1) Error severity / message-ID alerts

Severity levels 17–25 are the ones that matter operationally:

| Severity | Meaning |
|---|---|
| 17 | Insufficient resources (out of locks, disk, etc.) |
| 18 | Nonfatal internal error |
| 19 | Fatal error in resource (exceeded a limit) |
| 20 | Fatal error in the current process |
| 21 | Fatal error affecting all processes in the database |
| 22 | Fatal error: table integrity suspect |
| 23 | Fatal error: database integrity suspect |
| 24 | Fatal error: hardware error |
| 25 | Fatal system error |

```sql
-- One alert per severity 17–25 (commonly scripted in a loop)
EXEC msdb.dbo.sp_add_alert
    @name = N'Severity 019 Errors',
    @severity = 19, @notification_message = N'Severity 19 error detected.';
EXEC msdb.dbo.sp_add_notification
    @alert_name = N'Severity 019 Errors', @operator_name = N'DBA Team', @notification_method = 1; -- 1=email

-- Specific I/O message-ID alerts (these are the canaries for storage problems)
EXEC msdb.dbo.sp_add_alert @name = N'Error 823 - I/O failure', @message_id = 823;
EXEC msdb.dbo.sp_add_alert @name = N'Error 824 - Logical consistency', @message_id = 824;
EXEC msdb.dbo.sp_add_alert @name = N'Error 825 - Read retry',        @message_id = 825;
```

Always alert on **severity 19+** and **823/824/825**; these should page on-call. Error 825 in particular is an early warning of failing storage *before* hard corruption.

### 2) Performance-condition alerts

Fire when a SQL Server performance counter crosses a threshold (e.g., Page Life Expectancy falls below a value, log file % used rises above one).

```sql
EXEC msdb.dbo.sp_add_alert
    @name = N'Low Page Life Expectancy',
    @performance_condition = N'SQLServer:Buffer Manager|Page life expectancy||<|300';
```

### 3) WMI alerts

React to WMI events (e.g., DDL changes via the WMI Provider for Server Events). Powerful but heavier; use sparingly.

> A user-raised error must be logged (`RAISERROR ... WITH LOG` or `sp_addmessage` with `@with_log = 'true'`) for a severity alert to fire on it.

## Multiserver Administration (MSX / TSX)

For fleets, designate one instance as the **Master server (MSX)** and enlist others as **Target servers (TSX)**. You author multiserver jobs once on the MSX; targets download and run them and report history back. Good for applying the same maintenance jobs across many instances. Set up via the Agent "Multi Server Administration" wizard or `sp_msx_enlist`. Modern fleets often prefer external orchestration (Ola scripts deployed via CI, Azure Automation, dbatools/PowerShell) over MSX, but MSX remains valid.

## Azure SQL Database — Elastic Jobs (the Agent alternative)

Azure SQL Database has **no SQL Agent**. Use **Elastic Jobs** instead — a separate scheduling service designed to run T-SQL across one or many databases.

Components:

- **Elastic Job Agent** — an Azure resource backed by a *job database* (an Azure SQL DB that stores job metadata).
- **Job** — a unit of work with one or more **job steps** (T-SQL).
- **Target group** — defines which databases/servers/pools the job runs against (can fan out across many DBs).
- **Schedule** — recurrence on the job.

You define jobs by calling stored procedures in the job database (`jobs.sp_add_job`, `jobs.sp_add_jobstep`, `jobs.sp_add_target_group`, `jobs.sp_add_target_group_member`, `jobs.sp_update_job` for scheduling), or via PowerShell/ARM/Azure CLI.

```sql
-- In the Elastic Job *job database*:
EXEC jobs.sp_add_target_group 'AllAppDbs';
EXEC jobs.sp_add_target_group_member 'AllAppDbs',
     @target_type = 'SqlDatabase',
     @server_name = 'myserver.database.windows.net',
     @database_name = 'AppDb1';

EXEC jobs.sp_add_job @job_name = 'Update Stats', @description = 'Nightly stats refresh',
     @schedule_interval_type = 'Days', @schedule_interval_count = 1;

EXEC jobs.sp_add_jobstep @job_name = 'Update Stats',
     @command = N'EXEC sp_updatestats;',
     @target_group_name = 'AllAppDbs';
```

Mapping for the operations DBA:
- **Maintenance** (index/stats): run the *single-database* Ola variants, or simple `ALTER INDEX`/`UPDATE STATISTICS`, as Elastic Job steps fanned across the target group. (Azure SQL DB also does some auto-tuning/auto index management.)
- **Backups**: not your job — Azure SQL DB backups are fully managed; you don't schedule them.
- **Alerting/notifications**: use **Azure Monitor alerts**, **Action Groups**, and **Logic Apps** in place of Agent alerts + Database Mail.

## AWS RDS Agent Constraints

Agent runs on RDS, but:
- **No `sa`, no direct sysadmin, no OS access.** Your master user has a constrained role.
- **No `xp_cmdshell`**; CmdExec/PowerShell steps that need OS access generally won't work — keep steps to T-SQL.
- Native backup/restore goes through `rdsadmin.dbo.rds_backup_database` / `rds_restore_database` rather than `BACKUP`/`RESTORE`.
- Multi-AZ failovers and patching are managed by RDS; design jobs to be idempotent and tolerant of failover.

## Operational Checklist

- [ ] Jobs owned by a service login, not a person.
- [ ] Failure notification wired on **every** job to a monitored operator; a fail-safe operator configured.
- [ ] Database Mail tested (`sp_send_dbmail`) and Agent configured to use the profile.
- [ ] Alerts created for severity 19–25 and messages 823/824/825, with notifications.
- [ ] Retries set sensibly on transient-failure-prone steps; not masking deterministic failures.
- [ ] Non-T-SQL steps run under least-privilege proxies, not the Agent service account.
- [ ] Job history retention sized so you can investigate (raise `sp_purge_jobhistory` limits if needed).
