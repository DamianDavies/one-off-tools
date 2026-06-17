# CLAUDE.md — one-off-tools

## Repo layout
- Organise everything **by issue**: each task gets its own kebab-case subfolder
  (scripts + a short README + data files). Keep the root to the README index and
  `.gitignore`. Use `git mv` when relocating tracked files. CSVs are gitignored at
  any depth — override per-file with `git add -f` only when genuinely public.

## Linked servers / external systems
- **JOBPACCONNECT** — the Jobpac **DB2/400 (IBM i)** linked server. Library
  `JDHIGDTA01`; SQL naming (`JDHIGDTA01.TABLE`). Names starting with `#`
  (e.g. `#SYSPSPP`) are **real DB2 tables**, not SQL Server temp tables. Read via
  `OPENQUERY`; write via `EXEC('…') AT [JOBPACCONNECT]` in DB2 SQL (no `FROM`-clause
  UPDATE). RPC-out is enabled.
- **HOW** — the forms/inspections system: **MariaDB**, `cs_inform_*` / `cs_access_*`
  tables, via the `HOW` linked server (MSDASQL ODBC) and the `HOWdbaccess` SQL
  database. Inner `OPENQUERY` text is **MariaDB/MySQL dialect** (`curdate()`,
  `interval`, `date_sub`), single quotes doubled.

## Field Service (Dynamics 365) gotchas
- Bookings on **placeholder resources** (`Placeholder - <city>`, `Place Holders`)
  = **future maintenance years**, not real scheduled work — filter them out when
  judging whether a WO is actually scheduled.
- HOW form **`started_at` is unreliable**: it mirrors the last update, and
  **same-session create+complete forms get no `started_at` at all** (a HOW bug).
  Date forms by `created_at`.
- The three "Scheduled 15 mins" check flows (**WSRA / Site File Sharing / PCR**) each set
  their WO completion flag by listing WOs `startswith(msdyn_name, <jobcode>)` and updating
  `@first(...)`. The ListRecords step **must** be `$orderby=msdyn_name` (asc) or `@first`
  lands on the wrong WO for multi-WO maintenance jobs (flags a future placeholder, leaves
  the real one). Don't filter on `hig_assessedhours` — unreliably populated.
