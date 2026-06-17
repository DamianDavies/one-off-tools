# NEXT — 2026-06-15

## WSRA — backlog cleared ✅, but flow matching bug still OPEN ⚠️
- **Backlog done & verified:** applied the 78-row clean-up (`Risk Assessment Complete =
  Yes`); all 78 dropped out of the fresh post-fix `RA = No` export (0 remaining).
- **Only half the root cause was fixed.** The 28 May 2026 view change (`created_at`
  fallback for HOW's same-session no-`started_at` bug) fixed **single-WO jobs**. The
  **flow's `@first` WO-matching is still broken for multi-WO (maintenance) jobs** — it
  lists matches in default order and flags `@first`, hitting the wrong WO.
- **Live proof, 15 Jun:** QM8897 WSRA done 07:51 → flow flagged **QM8897E** (a 2035
  placeholder) and left **QM8897A** (the real current WO) at `No`. Two defects: false
  negative (A) + false positive (E).

## Still open
1. **Apply the flow fix** — set List-rows-Work-Orders `Order By = msdyn_name asc`, keep
   `@first` (current year = lowest *open* suffix; past years closed/excluded; placeholders
   are higher suffixes). Written up: `field-service-wsra-reconciliation/flow-matching-fix.md`.
   Verify closed past-years really are excluded (else add `statecode eq 0`).
2. **Manual cleanup now:** QM8897A → Yes; QM8897E → back to No.
- Reusable matcher (`field-service-wsra-reconciliation/`) stays for any future backlog;
  re-export fresh CSVs before a re-run.

## Reference
- Reported jobs: JM0075 / QM8915 / ZC0479 fixed via backlog; QR6800 / QR6801 self-resolved.
  QM8915B–F correctly stay `No` (future placeholder years).

## Other repo items (other sessions, already closed)
- `azure-gpv1-storage-migration` — done 2026-06-12.
- `sentinel-sourcecontrol-api-retirement` — no action required (investigation only).
