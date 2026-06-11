# NEXT — 2026-06-11

## This session
- Shipped the **Jobpac PM-mismatch daily SQL Agent job** (commits `fe9473b`, `5dc0e72`,
  pushed). Live on HIGDCSQL01, runs 22:00 daily; emails the mismatch set as an HTML table.
- **Reorganised the repo into per-issue subfolders**; rewrote the root README as UTF-8.
- **Investigated the Field Service "Risk Assessment not done" complaints (WSRA).** Root
  cause found, reconciliation rule agreed. **Nothing built yet for WSRA.**

## Where we got to (WSRA)
- Flag `hig_riskassessmentcomplete` on `msdyn_workorders` is set by a Power Automate flow
  (15-min) reading SQL view `HOWdbaccess.dbo.D365FS_WSRAs_started_yesterday`.
- Root cause: view keys off `started_at` in a ~1-day window; in HOW `started_at` is
  unreliable (mirrors last-update — later than `completed_at`). Plus the flow only updates
  `@first` WO via `startswith` + stale `datewindowstart`. → permanent misses, no retry.
- Agreed rule: set flag true if a **started** WSRA (`status <> 'NOT_STARTED'`) for the job
  has `created_at` within **12 months before the WO's earliest non-cancelled booking** date.

## Next to pick up
1. Run the HOW wide-lookback export query (in last assistant msg) — confirms job-code shape
   (e.g. `JM0075` vs `JM0075A`) before committing match logic.
2. Build offline matcher in new `field-service-wsra-reconciliation/` (mirror Site File):
   inputs = HOW WSRAs + WO export + bookings; outputs = ToSetTrue / NoValidWSRA / Expired /
   NoBookingDate. Then bulk-set via Edit-in-Excel.

## Open questions / caveats
- Matching rule + bucket scheme proposed but **not yet confirmed** by you.
- Assumed `created_at` (not `completed_at`) as the WSRA timeline date.
- PCR (ZC0509) and Site File are separate sibling flows — handle after WSRA.
- All 6 reported jobs confirmed to have started WSRAs in HOW but flag = false (diagnosis
  sound), but **no flags have been set** and no D365/HOW data pulled by me — handed to you.
