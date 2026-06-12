# WSRA (Worksite Risk Assessment) reconciliation

Field Service work orders show **"Risk Assessment not completed"** when the
crew has in fact done one. This finds the affected work orders and produces a
bulk-update list to set **Risk Assessment Complete = Yes**
(`hig_riskassessmentcomplete`).

## Why it happens (root cause)

The flag is set by a Power Automate flow (every 15 min) that reads the SQL
view `HOWdbaccess.dbo.D365FS_WSRAs_started_yesterday`, which `OPENQUERY`s the
**HOW** forms system (MariaDB, `cs_inform_*` tables) for *Worksite Risk
Assessment* forms, then sets the flag on the matching work order. It misses
records permanently, for four compounding reasons:

1. **1-day window keyed on `started_at`.** The view only returns forms with
   `started_at >= yesterday`. A flow outage of even a day drops that day's
   forms for good — no retry.
2. **`started_at` is unreliable.** In HOW it mirrors the *last update* and is
   often later than `completed_at` (observed: a form completed 24 Apr showed
   `started_at` of 1 Jun). So the window catches forms erratically. The matcher
   therefore dates each WSRA by **`created_at`**, which is stable.
3. **First-WO-only.** The flow updates `@first(...)` matching WO; other WOs for
   the same job stay No.
4. **Prefix + stale date filter.** `startswith(name, Job_Code)` plus
   `datewindowstart lt CutOffDate` excludes WOs with null/stale date windows.

## The rule

> A work order should be **Risk Assessment Complete = Yes** if there is a
> **started** WSRA (`status <> 'NOT_STARTED'`) for its job whose **`created_at`
> falls within the 12 months ending on the work order's date**.

- **Started, not completed** — a WSRA counts once it's been started
  (IN_PROGRESS or COMPLETE); `NOT_STARTED` forms don't.
- **WO date** = earliest non-cancelled **booking** Start Time, falling back to
  **Date Window Start** (bookings are more reliable — same finding as Site File).
- **12-month validity** — a WSRA is valid for one year, then a new one is
  required. The window naturally handles recurring **maintenance jobs**: this
  year's WO is covered by this year's WSRA; a future maintenance-year WO is not
  covered by an old WSRA (it correctly needs a fresh one). This replaces the
  flow's broken `startswith`/`@first` hack.

## Procedure

### 1. Export started WSRAs from HOW
Run [`Export-WSRAs-from-HOW.sql`](Export-WSRAs-from-HOW.sql) in SSMS against the
instance with the HOW linked server. Save the grid as **`wsras.csv`** here.

### 2. Export work orders from Dynamics
A view on **Work Orders** filtered to `Risk Assessment Complete = No`. Columns
(at least): Work Order Number (`msdyn_name`, starts with the job code), Date
Window Start, System Status, Risk Assessment Complete, and the hidden
`(Do Not Modify)` GUID column. Export → **Static Worksheet (CSV)** → **`wos.csv`**.

### 3. Export bookings (recommended)
**Bookable Resource Booking** export — Booking Name, Work Order, Start Time,
Status (filter Status ≠ Canceled). Save as **`bookings.csv`**.

### 4. Run the matcher
```powershell
.\Match-WSRAs.ps1
```
No auth, no network. Produces:
- `wsra-report.csv` — every WO classified.
- `wsra-toupdate.csv` — the rows to bulk-set Yes.

| Bucket | Meaning | Action |
|--------|---------|--------|
| ToSetTrue | flag No, started WSRA inside the 12-month window | Update |
| AlreadyComplete | flag already Yes | None |
| Expired | WSRA exists but only outside the window | Review (new WSRA?) |
| NoWSRA | no started WSRA for the job at all | Review (genuinely not done) |
| NoWoDate | no booking and no Date Window Start | Review |

### 5. Sanity-check, then bulk-update
Spot-check `wsra-report.csv` (especially `Expired`). Then in Dynamics: a
personal view of the `wsra-toupdate.csv` work orders → **Export to Excel →
Edit in Excel** → set **Risk Assessment Complete = Yes** → **Publish**.

### 6. Verify
Re-run the step-2 view; the corrected work orders should drop off.

## Caveats / things to verify before trusting a run

- **Column headers are guesses.** The `$Wo*Col` names at the top of
  `Match-WSRAs.ps1` must match your actual Dynamics export headers — adjust
  before relying on the output. Same for the HOW columns if you rename them.
- **6-char job codes.** `$JobCodeLength = 6` assumes Jobpac codes are 2 letters
  + 4 digits (e.g. `JM0075`). It also makes a WO named `JM0075A ...` match job
  `JM0075`. Confirm against the real export (the open `JM0075` vs `JM0075A`
  question).
- **Forward grace.** The window is strict "12 months *before* the WO date"
  (`$ForwardGraceDays = 0`). If crews start the WSRA on a work day later than
  the earliest booking, those show as `Expired`/`NoWSRA`; raise
  `-ForwardGraceDays` if that happens.
- **PCR and Site File are separate sibling flows** — not covered here.

## Status

**Built, not yet run** — no HOW/Dynamics data has been pulled and no flags set.
Diagnosis confirmed against the 6 reported jobs (all had started WSRAs in HOW
but `hig_riskassessmentcomplete = No`). Next: export `wsras.csv` / `wos.csv` /
`bookings.csv` and run the matcher; validate the job-code shape first.
