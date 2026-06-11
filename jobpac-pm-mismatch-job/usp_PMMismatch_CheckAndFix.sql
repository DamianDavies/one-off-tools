/* =====================================================================
   usp_PMMismatch_CheckAndFix
   ---------------------------------------------------------------------
   Daily reconciliation of the project manager on Jobpac (DB2/400) work
   orders. Compares BFMJOBSHS.PROJECTMAN against the "true" PM in
   JJOBIJIP.JIPMGR for the current JCAP period (firm '01'), logs the
   mismatch set, emails the count plus the rows (as an HTML table), then
   corrects PROJECTMAN.

   All three tables (BFMJOBSHS, JJOBIJIP, #SYSPSPP) live on the DB2/400
   linked server JOBPACCONNECT. #SYSPSPP is a real DB2 table name on the
   400 (IBM i allows '#'), NOT a SQL Server temp table.

   - CHECK (read): pushed to the 400 via OPENQUERY so the join runs there.
   - FIX  (write): pass-through EXEC(...) AT [JOBPACCONNECT] in DB2 SQL
                   (OPENQUERY is not reliably updatable via the IBM i
                   providers, and the correlated-subquery UPDATE can't be
                   expressed as an updatable rowset anyway).

   Prereqs:
     * Linked server JOBPACCONNECT with 'rpc out' = true (for EXEC ... AT).
     * Database Mail profile 'HIGDCSQL01' configured.
     * The login that runs this (the SQL Agent service account when
       scheduled) must map, via the linked server, to a 400 user with
       SELECT on the tables and UPDATE on BFMJOBSHS.

   Test safely first (no writes to the 400):
       EXEC dbo.usp_PMMismatch_CheckAndFix @ApplyFix = 0;
   ===================================================================== */
USE [JobpacConnect];   -- database on HIGDCSQL01 (same name as the linked server)
GO
CREATE OR ALTER PROCEDURE dbo.usp_PMMismatch_CheckAndFix
    @ApplyFix bit = 1            -- 0 = check + email only, no DB2 update
AS
BEGIN
    SET NOCOUNT ON;

    /* 1. CHECK - read the mismatch set from DB2/400 (join runs on the 400) */
    SELECT *
    INTO   #res
    FROM   OPENQUERY([JOBPACCONNECT], '
        SELECT a.period, a.job, a.projectman, b.jipmgr
        FROM   JDHIGDTA01.BFMJOBSHS a
        JOIN   JDHIGDTA01.JJOBIJIP  b
               ON a.firm = b.jifmcd
              AND a.job  = b.jijob
              AND a.period = (SELECT SPNUM1 FROM JDHIGDTA01.#SYSPSPP
                              WHERE  spfmcd = ''01'' AND sppcod = ''JCAP'')
        WHERE  a.projectman <> b.jipmgr
    ');

    DECLARE @rows int = (SELECT COUNT(*) FROM #res);

    /* 2. Emit the dataset so the Agent step log captures it */
    SELECT * FROM #res;

    /* 3. Email - summary line + the mismatch rows as an HTML table.
       (sp_send_dbmail @query can't see #res - it runs in its own session -
        so we build the table from #res into the body here.) */
    DECLARE @subject nvarchar(200) =
        N'PM-mismatch check - ' + CAST(@rows AS nvarchar(10)) + N' row(s)';

    DECLARE @html nvarchar(max) =
          N'<p>PM-mismatch check ran ' + CONVERT(varchar(19), SYSDATETIME(), 120) + N'.<br/>'
        + N'Rows needing correction: <b>' + CAST(@rows AS nvarchar(10)) + N'</b>'
        + CASE WHEN @ApplyFix = 1 THEN N' (fix applied).' ELSE N' (check only).' END
        + N'</p>';

    IF @rows > 0
        SET @html += N'<table border="1" cellpadding="4" cellspacing="0" '
            + N'style="border-collapse:collapse;font-family:Segoe UI,Arial,sans-serif;font-size:12px">'
            + N'<tr style="background:#f2f2f2">'
            + N'<th>Period</th><th>Job</th><th>PROJECTMAN (was)</th><th>JIPMGR (correct)</th></tr>'
            + CAST((
                SELECT td = r.period,     N'',
                       td = r.job,        N'',
                       td = r.projectman, N'',
                       td = r.jipmgr
                FROM   #res r
                ORDER BY r.job
                FOR XML PATH('tr'), TYPE
              ) AS nvarchar(max))
              -- the N'' break columns are REQUIRED: without them FOR XML
              -- merges the adjacent <td> columns into a single cell.
            + N'</table>';

    EXEC msdb.dbo.sp_send_dbmail
         @profile_name = N'HIGDCSQL01',
         @recipients   = N'ddavies@higgins.com.au',
         @subject      = @subject,
         @body         = @html,
         @body_format  = 'HTML';

    /* 4. FIX - pass the UPDATE through to the 400 (DB2-valid, no FROM clause) */
    IF @ApplyFix = 1 AND @rows > 0
    BEGIN
        EXEC ('
            UPDATE JDHIGDTA01.BFMJOBSHS A
            SET    A.PROJECTMAN = (SELECT b.JIPMGR FROM JDHIGDTA01.JJOBIJIP b
                                   WHERE A.FIRM = b.JIFMCD AND A.JOB = b.JIJOB
                                     AND A.PROJECTMAN <> b.JIPMGR)
            WHERE  A.PERIOD = (SELECT SPNUM1 FROM JDHIGDTA01.#SYSPSPP
                               WHERE SPFMCD = ''01'' AND SPPCOD = ''JCAP'')
              AND  EXISTS (SELECT 1 FROM JDHIGDTA01.JJOBIJIP b
                           WHERE A.FIRM = b.JIFMCD AND A.JOB = b.JIJOB
                             AND A.PROJECTMAN <> b.JIPMGR)
        ') AT [JOBPACCONNECT];
    END

    DROP TABLE #res;
END
GO
