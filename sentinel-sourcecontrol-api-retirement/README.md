# Microsoft Sentinel SourceControls API retirement

One-off **investigation only** — no code, no change required. Dated record that
we checked our exposure to a Microsoft Azure breaking-change notice and found it
to be a no-op for Higgins.

Subscription in scope: **Microsoft Azure Enterprise**
(`144944e1-e86f-4097-828c-c1eda1d015c6`) — the one named in the email.

## The notice

Microsoft is retiring older API versions used by the Sentinel **content-as-code
/ Repositories** capability. From **15 June 2026**, requests that **create or
manage** repository connections (`SourceControl` / `SourceControls` actions) on
the affected old API versions will fail. Supported versions going forward:
`2025-09-01`, `2025-06-01`, or `2025-07-01-preview`.

> Crucial qualifier from the email: **"Existing repository connections created
> with those APIs aren't affected and continue to operate."** So this only bites
> something that *actively creates / re-creates* a connection via an old API
> version — not connections that merely exist.

## Outcome (2026-06-12): NO ACTION REQUIRED

The breaking change does not affect us. The owner's decision was to record the
finding only (no email to the vendor at this time).

## Findings (checked 2026-06-12 with `az` REST, read-only)

Of the Log Analytics workspaces in the subscription, two looked Sentinel-related.
Only one is actually onboarded to Sentinel and it has exactly **one** repository
connection:

| Workspace | Sentinel onboarded? | Repo connections |
|---|---|---|
| `WorkspaceSentinel01` (`rgsentinel`) | **No** — not onboarded | none |
| `sentinel-ase-law` (`sentinel-ase-rg`) | Yes | **1** |

The single connection:

| Field | Value |
|---|---|
| Display name | **Trustwave Golden-Image** |
| Repo type | GitHub |
| Repo | `github.com/TWMSSISA/Client-897` (branch `main`) — **Trustwave's** org, not Higgins' |
| Content | AnalyticsRule, AutomationRule, HuntingQuery, Parser, Playbook, Workbook |
| Created | **2025-06-13** by `twramrestricted@trustwave.com` |
| Service principal creds expire | 2125-06-11 (effectively non-expiring) |

## Why this is a no-op for us

1. **The connection already exists** (created 2025-06-13) → explicitly exempt
   from the breaking change. It keeps deploying content after 15 June 2026.
2. **It is owned and operated by Trustwave** (our MSSP), pointing at a
   Trustwave-controlled GitHub repo. Higgins runs **no** first-party automation
   that creates or manages Sentinel repository connections (nothing in this tools
   repo or our pipelines does).
3. Any residual risk sits with **Trustwave**: if their provisioning tooling ever
   tears down and re-creates this connection on an old API version, that
   re-create would fail after the cutoff. That is theirs to fix by using a
   supported API version (`2025-06-01` or later).

The Microsoft email reached us only because the mailbox is the **subscription
contact** — it is a blanket notice, not evidence of exposed automation.

## Optional follow-up (not done — owner declined for now)

A one-line note to Trustwave could close the loop: confirm their tooling for the
"Trustwave Golden-Image" connection uses a supported API version, in case they
ever re-create it. Existing connection is exempt regardless, so this is
courtesy only.

## How to re-verify

```powershell
# 1. List Log Analytics workspaces
az monitor log-analytics workspace list `
  --subscription 144944e1-e86f-4097-828c-c1eda1d015c6 `
  --query "[].{name:name, rg:resourceGroup}" -o table

# 2. List Sentinel repo connections on the onboarded workspace
az rest --method get --url "https://management.azure.com/subscriptions/144944e1-e86f-4097-828c-c1eda1d015c6/resourceGroups/sentinel-ase-rg/providers/Microsoft.OperationalInsights/workspaces/sentinel-ase-law/providers/Microsoft.SecurityInsights/sourcecontrols?api-version=2025-09-01" -o json
```

A workspace that returns *"is not onboarded to Microsoft Sentinel"* has no
source controls to worry about.

## Verification status

- Read-only `az` REST discovery executed against Azure on 2026-06-12.
- One existing, vendor-owned connection found; it is exempt from the change.
- No Higgins-side automation creates Sentinel repository connections.
- **Conclusion: no action required.** Recorded for audit trail.
