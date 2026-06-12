# Azure GPv1 storage migration / cleanup

One-off response to Microsoft's retirement notice (tracking ID **XTKT-BW8**):
all general-purpose **v1** (GPv1) storage accounts must be moved to GPv2 by
**13 October 2026**, after which Microsoft auto-migrates them (with a billing
change) and blocks creation of new GPv1 accounts.

Subscription in scope: **Microsoft Azure Enterprise**
(`144944e1-e86f-4097-828c-c1eda1d015c6`) — the one named in the email.

## Findings (checked 2026-06-12 with `az`)

Of 19 storage accounts in the subscription, **5 are GPv1** (`Kind: Storage`).
The other 14 are already `StorageV2` and are unaffected. None are
`BlobStorage`-kind or Databricks-managed, so nothing qualifies for Microsoft's
"we migrate it for you" exemption — all 5 are our responsibility.

Each GPv1 account was checked for (a) what Function App / Web App binds it,
(b) data-plane transaction activity, and (c) actual contents (blob containers,
queues, tables, file shares). Activity was validated against a known-live
control account that showed 29/30 active days.

| Account | Resource group | Bound to | Activity (prior 90d, excl. today) | Contents | Decision |
|---|---|---|---|---|---|
| `higctautomationa68e` | higctautomation01-prod-rg | **HigCTAutomation-prod** fn app (running) | Active 29/30 days | — | **MIGRATE** (prod) |
| `d365oauthtokenrg819a` | d365OauthToken_rg | **d365OauthToken** fn app (running) | Bound & running | — | **MIGRATE** |
| `solutiontemplatef4fscaig` | SolutionTemplate-nfi14ji | **asschedulerc6zlsc2bt37** fn app (running) | Bound & running | — | **MIGRATE** (or decommission whole solution — see note) |
| `higctautofunctionapp01` | higctautomation01-prod-rg | nothing (prod app uses `…a68e`) | **0 days** | **1 blob container** (not empty) | **INSPECT then migrate-or-delete** |
| `dyn864c5ff1e0bc49f9` | DynamicsDeployments-australiasoutheast | nothing | **0 days** | **3 blob containers** (not empty) | **INSPECT then migrate-or-delete** |

> **Correction (after deeper checks).** An initial 30-day, Function-App-only,
> no-content pass labelled the bottom two accounts as safe "DELETE" orphans.
> Hardening the delete script surfaced that this was wrong: both accounts still
> hold blob containers (1 and 3), so they are **idle but NOT empty**. A naive
> delete would have destroyed real containers. They are now BLOCKED pending a
> manual look at the container contents.

### Why these decisions

- The GPv1 → GPv2 conversion is an **in-place upgrade**: no data copy, no new
  account, **no change to blob/queue/table endpoint URLs**, and no downtime.
  Anything pointing at the account (Function App connection strings) keeps
  working. The only real change is billing flips to the GPv2 model — negligible
  for these small automation/token accounts.
- The three bound accounts are clearly in use by running Function Apps → migrate.
- The two "orphans" have **zero data-plane activity over the prior 90 days**
  (the apparent "1 active day" on `higctautofunctionapp01` was this script's own
  container-listing probe **today** — the activity gate now excludes the current
  day so it cannot self-trip). But both still contain blob containers, so the
  safe outcome is to **inspect the contents first**: if disposable, delete; if
  not, migrate them to GPv2 like the rest.

## Scripts

### `Migrate-Gpv1Storage.ps1`
Upgrades the **3 live** accounts to GPv2. Dry-run by default (prints what it
would do); pass `-Apply` to actually run the upgrade. For each account it:
1. confirms the current kind is `Storage` (skips if already `StorageV2`),
2. runs `az storage account update --upgrade-to-v2`,
3. verifies the new kind is `StorageV2`, and
4. re-checks the bound Function App is still `Running`.

```powershell
# Preview (no changes):
./Migrate-Gpv1Storage.ps1
# Apply:
./Migrate-Gpv1Storage.ps1 -Apply
```

> The upgrade is one-way (you cannot convert GPv2 back to GPv1) but is
> non-destructive. Run it in a quiet window for the prod accounts and confirm
> the Function Apps still tick over afterwards.

### `Remove-OrphanGpv1Storage.ps1`
Decommissions the two idle accounts — kept deliberately separate from the
migration so the destructive step is reviewed on its own. Three safety gates,
**all fail closed** (a failed `az` call aborts rather than assuming "safe"):

1. **Activity** — zero data-plane transactions over the 90 days *ending at
   midnight UTC today* (today is excluded so the script's own probing can't
   self-trip the gate). A failed metrics query aborts the account.
2. **References** — the account name must not appear in any Function App **or
   Web App** setting / connection string. A failed index build aborts the run.
3. **Emptiness** — no blob containers, queues, tables, or file shares. If
   contents can't be verified, the account is BLOCKED unless `-Force`.

Dry-run by default; `-Apply` to delete; `-Force` overrides **only** the
emptiness gate (after you've manually confirmed the contents are disposable).

```powershell
# Safety report only (no changes):
./Remove-OrphanGpv1Storage.ps1
# Delete after reviewing the report AND confirming contents are disposable:
./Remove-OrphanGpv1Storage.ps1 -Apply -Force
```

> **Environment limitation seen on 2026-06-12:** this machine sits behind a
> corporate proxy that intercepts the **queue** endpoint with a self-signed
> cert, so `az storage queue list` fails TLS verification
> (`CERTIFICATE_VERIFY_FAILED`). Blob container listing works; queue/table/share
> do not. The emptiness gate therefore can't fully complete here and blocks both
> accounts. Verify contents in the **Azure Portal** (browser, different trust
> chain) before using `-Force`. Do **not** disable `az` cert verification to work
> around a corporate proxy.
>
> Implementation notes baked into the script (don't regress them): this shell
> runs with `$PSNativeCommandUseErrorActionPreference = $false`, so every `az`
> call is wrapped in `Invoke-Az` to check `$LASTEXITCODE` and fail closed; the
> storage key is passed via `AZURE_STORAGE_*` env vars (not CLI args, which a
> base64 key breaks on Windows `cmd`); and counts use `-o json` + PowerShell
> rather than a jmespath `length(@)` (the bare token goes unquoted to `cmd` and
> breaks on the parentheses).

## Open questions for the owner

1. **`higctautofunctionapp01` (1 container) and `dyn864…` (3 containers).**
   Both are idle but not empty. Look at the container contents in the portal:
   - Disposable (old logs, stale deployment artifacts) → delete with
     `-Apply -Force`.
   - Anything worth keeping → migrate to GPv2 instead (add them to
     `Migrate-Gpv1Storage.ps1`'s target list).
2. **`solutiontemplatef4fscaig`** backs a marketplace "solution template"
   scheduler Function App (`asschedulerc6zlsc2bt37`). It is running, so the safe
   default is to migrate it. But if that whole solution is no longer wanted, the
   better move is to decommission the app **and** its storage together rather
   than migrate.

## Verification status

- Read-only discovery and **dry-runs of both scripts** were executed live
  against Azure on 2026-06-12.
- `Migrate-Gpv1Storage.ps1` dry-run: clean — correctly identifies the 3 live
  GPv1 accounts. **Not** run with `-Apply` (prod write, left for an operator).
- `Remove-OrphanGpv1Storage.ps1` dry-run: gates work and currently **BLOCK both
  accounts** (non-empty + queue endpoint unverifiable behind the proxy). No
  deletion has occurred. Before any `-Apply -Force`, confirm container contents
  in the portal.
