# Flow fix — WSRA flag lands on the wrong work order (multi-WO jobs)

**Status:** ✅ Applied & verified 2026-06-17 — `$orderby = msdyn_name` (ascending) added to
the List-rows-Work-Orders step on **all three sibling flows** (WSRA `fd3f6c3d`, Site File
Sharing `09f39d25`, PCR `0a93a4eb`); `@first` now lands on the current WO. Verified live via
the Flow API ($orderby present, last-modified moved to publish time).

## Defect

The 28 May 2026 view fix (`created_at` fallback for HOW's same-session
no-`started_at` bug) fixed *single-WO* jobs. **Multi-WO jobs (maintenance jobs
with suffixes A–J) still mis-flag**, because the flow's "List rows — Work Orders"
step returns matches in **default order** and then updates `@first(...)`.

Live example, 15 Jun 2026: a WSRA for **QM8897** was completed 07:51. ~7 hours
(28 runs) later the flow had flagged **QM8897E** (a 2035 placeholder year) and
left **QM8897A** (the real current WO) at `No`. So one bug, two defects:
- **False negative** — the real WO stays `No` (the user-visible complaint).
- **False positive** — a future placeholder year is marked `Yes`, hiding a real
  gap when its year arrives.

This is the flow-side matching; the view fix never touched it.

## Fix (small)

On the **List rows — Work Orders** action, set **Order By = `msdyn_name asc`**,
and keep the existing `@first(...)` in the update step.

Why this works, given the confirmed facts:
- The **current** year's WO is the **lowest** suffix (A=this year, B–J=future
  years). Confirmed: QM8897A and QM8915A are the real current WOs; higher
  letters are placeholder bookings 2027+.
- **Past years are closed and filtered out** of the result (confirmed), so the
  lowest *open* suffix is always the current year.
- Future-year placeholders are always *higher* suffixes, so they sort after the
  current WO and never become `@first`.

So `asc` + `@first` = the current year's WO. **Ascending, not descending** —
descending would pick the furthest-future placeholder (e.g. QM8897J / 2035),
which is the worst choice.

## Verify before trusting

1. **Confirm closed past-years really are excluded** from the List rows result.
   If they aren't (e.g. they stay `Scheduled`), add a state filter
   (`statecode eq 0`, Active) — otherwise `asc` could pick a closed year-1 WO.
2. After applying, take a multi-WO job whose WSRA was just completed and confirm
   the **lowest open** WO flips to `Yes` (not a placeholder).

## Known residual (accepted)

Jobs with **multiple concurrent real WOs** (e.g. EM1020 had B/C/D all genuine)
still only get **one** flagged by `@first`. Confirmed rare, so accepted. If it
ever matters, change the update to flag *all* matched rows, not `@first`.

## Immediate manual cleanup (independent of the flow change)

- **QM8897A** → set `Risk Assessment Complete = Yes` (WSRA done 15 Jun, ID 587989).
- **QM8897E** → set back to `No` (placeholder year, wrongly flagged by the flow).
