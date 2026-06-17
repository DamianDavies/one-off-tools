# NEXT — 2026-06-15

## WSRA — RESOLVED ✅
- **Backlog cleared & verified:** the 78-row clean-up applied; all 78 dropped out of the
  fresh post-fix `RA = No` export (0 remaining).
- **Both halves of the root cause now fixed:**
  - *View* (28 May 2026): `created_at` fallback for HOW's same-session no-`started_at` bug
    — fixed single-WO jobs.
  - *Flow* (15 Jun 2026): added `$orderby = msdyn_name` (asc) to List-rows-Work-Orders so
    `@first` lands on the current WO (lowest open suffix) not a future placeholder —
    fixed multi-WO maintenance jobs. **Verified working.** See `flow-matching-fix.md`.

## Sibling flows — all fixed ✅
- All three "Scheduled 15 mins" check flows — **WSRA, Site File Sharing, PCR** — had the
  same `@first`-on-unsorted-ListRecords bug, and all three now have `$orderby = msdyn_name`
  (asc) **live** (verified 2026-06-17 via the Flow API: orderby present, last-modified moved).

## Closed out — nothing outstanding
- **QM8897 cleanup done:** QM8897A = Yes, QM8897E = No.
- **Placeholder false-positives checked — all clear** (no pre-fix mis-flags to sweep).
- Reusable matchers (`field-service-wsra-reconciliation/`, `site-file-shared-reconciliation/`)
  stay available if a future backlog ever arises.

## Reference
- Reported jobs: JM0075 / QM8915 / ZC0479 fixed via backlog; QR6800 / QR6801 self-resolved.
  QM8915B–F correctly stay `No` (future placeholder years).

## Other repo items (other sessions, already closed)
- `azure-gpv1-storage-migration` — done 2026-06-12.
- `sentinel-sourcecontrol-api-retirement` — no action required (investigation only).
