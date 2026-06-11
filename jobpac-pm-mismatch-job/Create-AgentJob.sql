/* =====================================================================
   Create-AgentJob.sql
   ---------------------------------------------------------------------
   Creates the daily SQL Server Agent job that runs
   dbo.usp_PMMismatch_CheckAndFix on HIGDCSQL01.

   FILL IN before running:
     @DbName    - the database on HIGDCSQL01 that owns the proc
     @StartTime - run time as HHMMSS integer (220000 = 22:00:00)
     @Owner     - job owner login

   The job is a single TSQL step that calls the proc. @flags = 8 writes
   the step output (the mismatch dataset) to the step log table; read it
   back with:
       EXEC msdb.dbo.sp_help_jobsteplog @job_name = N'Daily 22:00 - PM Mismatch Check and Fix';
   ===================================================================== */
USE [msdb];
GO
DECLARE @JobName   sysname = N'Daily 22:00 - PM Mismatch Check and Fix';
DECLARE @DbName    sysname = N'JobpacConnect';   -- DB on HIGDCSQL01 (note: same name as the linked server)
DECLARE @StartTime int     = 220000;       -- 22:00:00 (HHMMSS)
DECLARE @Owner     sysname = N'sa';

BEGIN TRANSACTION;
DECLARE @rc int, @JobId uniqueidentifier;

EXEC @rc = msdb.dbo.sp_add_job
     @job_name = @JobName, @enabled = 1, @owner_login_name = @Owner,
     @description = N'Daily: check BFMJOBSHS PM vs JJOBIJIP on Jobpac (DB2/400), log the mismatch set, email the count, then correct PROJECTMAN.',
     @job_id = @JobId OUTPUT;
IF @rc <> 0 GOTO Fail;

EXEC @rc = msdb.dbo.sp_add_jobstep
     @job_id = @JobId, @step_id = 1, @step_name = N'Check, email, fix',
     @subsystem = N'TSQL', @database_name = @DbName,
     @command = N'EXEC dbo.usp_PMMismatch_CheckAndFix @ApplyFix = 1;',
     @flags = 8,                            -- write step output (dataset) to log table
     @on_success_action = 1, @on_fail_action = 2;
IF @rc <> 0 GOTO Fail;

EXEC @rc = msdb.dbo.sp_add_schedule
     @schedule_name = N'Daily once', @enabled = 1,
     @freq_type = 4, @freq_interval = 1, @freq_subday_type = 1,
     @active_start_time = @StartTime;
IF @rc <> 0 GOTO Fail;

EXEC @rc = msdb.dbo.sp_attach_schedule @job_id = @JobId, @schedule_name = N'Daily once';
IF @rc <> 0 GOTO Fail;

EXEC @rc = msdb.dbo.sp_add_jobserver @job_id = @JobId, @server_name = N'(local)';
IF @rc <> 0 GOTO Fail;

COMMIT TRANSACTION;
PRINT 'Job created: ' + @JobName;
RETURN;
Fail:
IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
PRINT 'Job creation FAILED (rc=' + CAST(@rc AS varchar(10)) + ').';
GO
