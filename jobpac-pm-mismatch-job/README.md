# Jobpac PM-mismatch daily check & fix

A daily SQL Server Agent job that reconciles the project manager on Jobpac
(DB2/400) work orders: it compares `BFMJOBSHS.PROJECTMAN` against the
authoritative PM in `JJOBIJIP.JIPMGR` for the current **JCAP** period
(firm `'01'`), records the mismatches, emails the count plus the rows (as an
HTML table), then corrects `PROJECTMAN`.

## The setup

All three tables live on the **DB2/400 linked server `JOBPACCONNECT`**:

- `BFMJOBSHS` — job header (holds `PROJECTMAN`)
- `JJOBIJIP` — the source of truth for the PM (`JIPMGR`)
- `#SYSPSPP` — system-period table. **This is a real DB2 table name**
  (IBM i allows `#` in identifiers), *not* a SQL Server temp table.

All three are library-qualified with **`JDHIGDTA01`** in the scripts
(e.g. `JDHIGDTA01.BFMJOBSHS`), so resolution doesn't depend on the
linked-server connection's library list.

The work runs on `HIGDCSQL01` (daily at **22:00**) and is split into:

| File | What it does |
|------|--------------|
| `usp_PMMismatch_CheckAndFix.sql` | The stored procedure: CHECK (read) + email + FIX (write). |
| `Create-AgentJob.sql` | Creates the daily Agent job that calls the proc. |

## How it talks to the 400 (and why)

- **CHECK = `OPENQUERY([JOBPACCONNECT], '…')`.** The whole join is pushed
  down to DB2 so it executes on the 400 and only the mismatch rows come
  back across the link. The result set returns to SQL Server, where the
  logging and email happen.
- **FIX = `EXEC('…UPDATE…') AT [JOBPACCONNECT]`.** A pass-through, run by
  DB2 itself. `UPDATE OPENQUERY(...)` is unreliable with the IBM i
  providers, and a correlated-subquery update can't be expressed as an
  updatable rowset anyway.
- The FIX is **DB2 SQL, not T-SQL** — it uses the standard correlated
  subquery with **no `FROM` clause** (the T-SQL `UPDATE … FROM` form is
  invalid on DB2).

## Deploy

1. **Enable RPC out** on the linked server (needed for `EXEC … AT`):
   ```sql
   EXEC sp_serveroption N'JOBPACCONNECT', N'rpc out', N'true';
   ```
2. Create the proc — run `usp_PMMismatch_CheckAndFix.sql` (it targets the
   `JobpacConnect` database on HIGDCSQL01; emails via Database Mail profile
   `HIGDCSQL01`).
3. **Test with no writes to the 400:**
   ```sql
   EXEC dbo.usp_PMMismatch_CheckAndFix @ApplyFix = 0;
   ```
   Confirm the rows look right and the email arrives.
4. Run once with `@ApplyFix = 1` by hand to confirm the write.
5. Create the job — fill in `@DbName` / `@StartTime` / `@Owner` in
   `Create-AgentJob.sql` and run it.

Read back a run's logged dataset:
```sql
EXEC msdb.dbo.sp_help_jobsteplog @job_name = N'Daily 22:00 - PM Mismatch Check and Fix';
```

## Gotchas that bite (environment, not the script)

- **Security context.** Scheduled, the job runs as the **SQL Agent service
  account**, not you. That account's `JOBPACCONNECT` login mapping must map
  to a 400 user with SELECT on the tables and UPDATE on `BFMJOBSHS`.
  "Works by hand, fails as a job" is almost always this.
- **Naming convention.** Names are library-qualified with SQL naming
  (`JDHIGDTA01.BFMJOBSHS`, `.` separator). If the `JOBPACCONNECT` provider
  is set to *system* naming, a parse error on the `@ApplyFix = 0` test means
  switching the separator to `/` (`JDHIGDTA01/BFMJOBSHS`).
- **`SET` subquery cardinality.** The FIX assumes one `JIPMGR` per
  `FIRM`+`JOB`. If a firm/job ever maps to more than one, DB2 raises
  "subquery returned more than one row." (Original logic, kept as-is.)
- **It auto-edits production daily.** Run with `@ApplyFix = 0` if you ever
  want alert-only.
- **Case-sensitivity is intentional.** The comparison is case-sensitive, so
  case-only differences (e.g. `Plew` vs `PLEW`) count as mismatches and get
  "corrected". This is deliberate — kept as-is so a daily row also confirms
  the job is reaching the 400. Do **not** wrap the comparison in `UPPER()`.

## Status

**Deployed and live** — tested (`@ApplyFix = 0` then `@ApplyFix = 1`) and
scheduled on HIGDCSQL01 as Agent job **`Daily 22:00 - PM Mismatch Check and
Fix`**, running daily at 22:00.

Config: database `JobpacConnect` on HIGDCSQL01; library `JDHIGDTA01`; linked
server `JOBPACCONNECT` (RPC-out on); Database Mail profile `HIGDCSQL01`;
Agent service account has the 400 grants.
