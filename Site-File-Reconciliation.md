# Site File Shared reconciliation

One-off procedure to set `Site File Shared = Yes` on Dynamics 365 work orders
that appear in the SharePoint "JMS Site File Log" list within +/- 3 months of
their scheduled date.

## Why this is split into manual + offline steps

Originally this was attempted as a single PowerShell script that authenticated
to both Dataverse and SharePoint and did everything in-process. That hit:

- The legacy `Microsoft.Xrm.Data.PowerShell` module (SOAP-based, Desktop-only,
  being phased out).
- Conditional Access blocking OAuth device-code flow.
- `PnP.PowerShell -Interactive` being retired by Microsoft in Sept 2024.
- Assembly conflicts between `Az.Accounts` and `PnP.PowerShell` in the same
  session.

For a one-off, it's faster to use Microsoft's built-in export/import tooling
and let the script just do the matching logic.

## Procedure

### 1. Export work orders from Dynamics

In Dynamics 365, build a view on **Work Orders**:

- Filter: `Site File Shared = No`
- Columns (at minimum): `Work Order Number`, `Date Window Start`
- Save view, then Export -> **Static Worksheet** (CSV)
- Save as `wos.csv` next to the matcher script.

The export will include hidden `(Do Not Modify)` columns -- leave them in;
the matcher reads the `WO Number` GUID column from there for the Edit-in-Excel
step later.

### 2. Export the SharePoint list

Open the **JMS Site File Log** list -> **Export to Excel** -> save as
`sp.csv` next to the matcher script.

Required columns: `Title`, `Created`.

### 2b. Export resource bookings (recommended)

The WO `Date Window Start` field can be stale when bookings are
rescheduled. Re-export the real schedule from the related
**Bookable Resource Booking** entity:

- Columns: `Booking Name`, `Work Order`, `Start Time`, `Status`
- Filter (recommended): `Status` does not equal `Canceled`
- Export -> **Static Worksheet**, save as `bookings.csv`

If `bookings.csv` exists, the matcher uses the **earliest non-cancelled
booking Start Time** per WO as the date. If a WO has no booking, or
`bookings.csv` is missing, it falls back to `Date Window Start`. Each row
in the report has a `DateSource` column showing which path was used.

### 3. Run the matcher

```powershell
.\Match-SiteFiles.ps1
```

No auth, no modules, no network calls. Produces two files:

- `site-file-shared-report.csv` -- every work order classified.
- `site-file-shared-toupdate.csv` -- just the rows ready to bulk-set Yes.

Classifications:

| Match              | Meaning                                                  | Action |
|--------------------|----------------------------------------------------------|--------|
| Single             | Exactly one SharePoint match within +/- 3 months         | Update |
| Ambiguous          | Multiple SharePoint matches in range (recurring shares)  | Update |
| OutOfDateRange     | Prefix exists in SharePoint, but no date in range        | Review |
| NoSharePointEntry  | Prefix not in SharePoint at all                          | Skip   |
| NoWoDate           | Work order has no `Date Window Start`                    | Review |
| Unscheduled        | `System Status = Unscheduled` -- no real plan to match   | Skip   |

### 4. Sanity-check the report

Open `site-file-shared-report.csv` and spot-check a few rows in each bucket.
Especially the `Ambiguous` ones -- decide manually which (if any) SharePoint
entry matches, and add those work-order numbers to the to-update list by hand
if appropriate.

### 5. Bulk-update Dynamics via Edit in Excel

In Dynamics 365:

1. Create a personal view of **Work Orders** filtered to the work-order
   numbers in `site-file-shared-toupdate.csv`. Easiest way: use Advanced Find,
   condition `Work Order Number In`, paste the values.
2. Switch to that view.
3. Click **Export to Excel -> Open in Excel Online (Edit)** (or the desktop
   "Edit in Excel" if your environment offers it).
4. Set the `Site File Shared` column to `Yes` for every row.
5. Click **Publish** (or "Track changes -> Publish"). Dynamics applies the
   updates back to the records.

### 6. Verify

Re-run the original Dynamics view from step 1 and confirm the affected work
orders no longer appear.

## Files in this folder

- `Match-SiteFiles.ps1` -- the offline matcher.
- `wos.csv` -- Dynamics export (gitignored if added).
- `sp.csv` -- SharePoint export (gitignored if added).
- `site-file-shared-report.csv` -- full output, all classifications.
- `site-file-shared-toupdate.csv` -- the bulk-update worksheet.
