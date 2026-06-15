# NEXT — 2026-06-15

## WSRA reconciliation — COMPLETE ✅
- Applied the 78-row backlog (`Risk Assessment Complete = Yes`) and **verified**: all 78
  dropped out of the fresh post-fix `RA = No` export (0 remaining).
- Root cause was already fixed at source: the HOW view `D365FS_WSRAs_started_yesterday`
  was changed **2026-05-28** (confirmed via `sys.objects.modify_date`) to fall back to
  `created_at` when a same-session create+complete form gets no `started_at` (a HOW bug).
  Clean June confirms it's working — the 78 were pure pre-fix backlog.
- Reported jobs: JM0075 / QM8915 / ZC0479 fixed via the backlog; QR6800 / QR6801 had
  already self-resolved. QM8915B–F correctly stay `No` — future maintenance years
  (placeholder bookings 2027–2031, not due; their `Date Window Start` is a stale 2026
  default, which is why we date WOs off the booking resource, not that field).

## Nothing outstanding
- No recurring re-run, no durable fix, no event-driven redesign needed.
- `field-service-wsra-reconciliation/` remains as a reusable matcher if a backlog ever
  recurs (e.g. the HOW view regresses). Re-export fresh `wsras.csv` / `wos.csv` (RA=No) /
  `bookings.csv` before any re-run; column-name + 6-char-job-code assumptions hold for the
  current export format.

## Other repo items (other sessions, already closed)
- `azure-gpv1-storage-migration` — done 2026-06-12.
- `sentinel-sourcecontrol-api-retirement` — no action required (investigation only).
