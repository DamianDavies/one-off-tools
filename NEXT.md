# NEXT — 2026-06-12

## This session
- Built the **WSRA (Worksite Risk Assessment) reconciliation** in
  `field-service-wsra-reconciliation/` (Export-WSRAs-from-HOW.sql, Match-WSRAs.ps1, README).
- Diagnosed root cause, then validated the matcher against real exports over several
  iterations: column-name fixes, headerless `wsras.csv`, and the key insight —
  **placeholder-resource filtering** (bookings on `Placeholder - <city>` / `Place Holders`
  resources = future maintenance years, not real scheduled work).
- Ran concurrently with the azure-gpv1 session — both on `main`, isolated by folder +
  scoped `git add` (never `-A`).

## Result (ready to apply)
- `wsra-toupdate.csv` = **78 work orders** to set `Risk Assessment Complete = Yes`
  (66 past/current + 12 genuinely future-booked). All have WO GUIDs; zero duplicates.
- Buckets: 78 ToSetTrue, 806 NotScheduled (placeholder-only), 20 Expired, 47 NoWSRA,
  1062 Unscheduled.

## Next — user doing MONDAY
1. Bulk-set the 78: Dynamics view of those WOs → Export to Excel → Edit in Excel →
   `Risk Assessment Complete = Yes` → Publish.
2. Re-run the `RA Complete = No` view to confirm they drop off.
3. Spot-check the 20 `Expired` (likely need a fresh WSRA, not a flag flip).
4. Confirm multi-WO jobs (EM1020 B/C/D, MM3652, PM7637) are all meant to be flagged.

## Open / caveats
- Validated against real data but **no flags set in production yet**.
- Column-name + 6-char-job-code assumptions hold for *this* export format; re-check if it changes.
- One-off backlog clear only — the **Power Automate flow/view still has the bugs**
  (`started_at` / 1-day window / matching) and will keep missing. Durable fix = separate piece.
- **ZC0509** was a **PCR** complaint (separate sibling flow), not WSRA — not handled here.
- Original 6 jobs: JM0075/QM8915/ZC0479 are in the 78; QR6800/QR6801 already Yes.
