# one-off-tools

Small, self-contained tools and scripts for one-off data jobs. **Each issue
gets its own subfolder** (kebab-case, named for the problem) containing the
scripts, a short `README.md`, and any data files. New issue -> new subfolder.

CSV data files are gitignored by default (`.gitignore` excludes `*.csv` at any
depth) because these exports usually contain customer / employee / work-order
data. Override per-file with `git add -f` only when a CSV is genuinely public.

## Issues

| Folder | What it's for |
|--------|---------------|
| [`site-file-shared-reconciliation/`](site-file-shared-reconciliation/) | Set `Site File Shared = Yes` on D365 work orders that match the SharePoint "JMS Site File Log" within +/-3 months. Offline matcher + anomaly scanner. |
| [`power-automate-flow-runs/`](power-automate-flow-runs/) | Pull Power Automate flow-run history for a given day (Brisbane time) via the Flow management API. |
| [`uipath-repo-cleanup/`](uipath-repo-cleanup/) | Add a UiPath `.gitignore` to each repo under a root and untrack generated/cache files. |
| [`jobpac-pm-mismatch-job/`](jobpac-pm-mismatch-job/) | Daily SQL Agent job: check/fix the project manager on Jobpac (DB2/400) work orders, via a linked server. |
| [`azure-gpv1-storage-migration/`](azure-gpv1-storage-migration/) | Response to Azure GPv1 storage retirement (XTKT-BW8, 13 Oct 2026). **Done 2026-06-12:** all 5 GPv1 accounts upgraded in place to GPv2; zero GPv1 remain. Fail-closed PowerShell scripts. |
