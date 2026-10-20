# Rule: Phase Discipline and Human Sign-off Gates

Applies to: `tfe-migration` mode, `tfe-migration-assistant` skill.

The migration is divided into exactly four phases executed in strict linear order.
No phase may begin until its predecessor's sign-off gate is cleared.
No phase may be skipped, abbreviated, or merged with another.

---

## Phase Execution Order

```
Phase 0 (Session Setup)
    ↓  [GATE-0]
Phase 1 (Pre-flight Inventory)
    ↓  [GATE-1]
Phase 2 (TFE Workspace Creation)
    ↓  [GATE-2]
Phase 3 (State Migration)        ← per-workspace inner gate applies here
    ↓  [GATE-3]
Phase 4 (Post-migration Validation)
    ↓  [GATE-4]
Session Close
```

Jumping from Phase 1 directly to Phase 3, or re-entering Phase 2 after Phase 3 has started,
is not permitted without explicit operator acknowledgement of the out-of-order action and a
written reason recorded in the migration report.

---

## Sign-off Gate Definitions

Each gate is a hard stop. Use `ask_followup_question` for every gate.
Do not proceed until the user selects or types an affirmative response.

### GATE-0 — Session Setup Complete
Trigger: All prerequisites confirmed (`terraform`, `curl`, `jq` present; `$TFE_TOKEN` set;
`TFE_HOSTNAME`, `TFE_ORG`, `PROJECT_ROOT` collected).

Prompt the user:
> "Prerequisites verified. Ready to begin Phase 1 Pre-flight Inventory?
> Confirm to continue, or Cancel to abort the session."

Choices: **Confirm** | **Cancel**
On Cancel: print a session abort message, do nothing further.

### GATE-1 — Inventory Reviewed and Scope Confirmed
Trigger: `preflight-inventory.sh` has completed without error and the summary table has been
shown to the user.

Prompt the user:
> "Inventory complete. Review the table above.
> - Any ❌ BLOCKED workspaces will be excluded unless you resolve the issue first.
> - Any ⚠️ WARNING workspaces are included but flagged.
> Confirm the workspace scope to proceed to Phase 2 (TFE Workspace Creation),
> or Edit to adjust the workspace list."

Choices: **Confirm scope** | **Edit exclusions** | **Abort**
On "Edit exclusions": ask the user to list workspace names to exclude, update the confirmed
list, re-display the trimmed table, then re-present GATE-1.
On Abort: write partial inventory to `{PROJECT_ROOT}/tfe-migration-report.md` and stop.

### GATE-2 — Workspace Creation Plan Approved
Trigger: The workspace name mapping table (CE directory → TFE workspace name) and variable
upload plan have been shown to the user.

Prompt the user:
> "The following TFE workspaces will be created and variables uploaded (see table above).
> No state has been touched yet — this is still fully reversible.
> Approve to proceed to Phase 3 (State Migration), or Revise to change workspace names."

Choices: **Approve** | **Revise names** | **Abort**
On "Revise names": accept name overrides, redisplay the mapping, re-present GATE-2.
On Abort: no TFE resources have been created yet if gate fires before any API call;
if workspaces were already created, surface the TFE workspace IDs and instruct the user
to delete them manually or via the rollback procedure.

### GATE-3 — Per-workspace State Push Approved
Trigger: Immediately before `terraform state push` for **each individual workspace**.

Prompt the user:
> "About to push state for workspace **{workspace-name}**.
> Backup confirmed at: /tmp/tfe-migration-backups/{workspace-name}-{timestamp}.tfstate
> TFE workspace locked: {workspace-id}
> Proceed with state push?"

Choices: **Push** | **Skip this workspace** | **Abort all remaining**
On "Skip": unlock the workspace, mark it SKIPPED in the migration report, move to the next.
On "Abort all remaining": unlock any currently locked workspace, write progress to the
migration report, stop. Do not attempt remaining workspaces.

### GATE-4 — Validation Report Reviewed
Trigger: `post-migration-validate.sh` has completed and the results table has been shown.

Prompt the user:
> "Validation complete (see table above).
> - ✅ MIGRATED workspaces are confirmed healthy.
> - ⚠️ DRIFT workspaces have plan changes — review before closing.
> - ❌ FAILED workspaces require remediation before closing.
> Acknowledge to finalise the session and write the migration report."

Choices: **Acknowledge and close** | **Re-run validation** | **Investigate a failure**
On "Re-run validation": re-run the script and re-present GATE-4.
On "Investigate a failure": ask which workspace, surface its full plan output and errors,
then re-present GATE-4.
On "Acknowledge and close": write `{PROJECT_ROOT}/tfe-migration-report.md` and end the session.

---

## Out-of-phase Requests

If the user asks to perform a Phase N action while the session is in Phase M (M ≠ N):

1. State the current phase clearly.
2. Explain what phase the requested action belongs to.
3. If M < N (jumping ahead): refuse and explain which intervening gates must be cleared first.
4. If M > N (going backward): warn that re-entering an earlier phase risks inconsistency,
   ask for a written reason, and require explicit confirmation before proceeding.

---

## Partial Migration Resume

If a session was interrupted mid-migration (e.g. GATE-3 "Abort all remaining" was used,
or the user re-opens the conversation), do not restart from Phase 0.

Instead:
1. Check whether `/tmp/tfe-migration-confirmed.json` and `/tmp/tfe-migration-completed.txt`
   exist. If they do, present the in-progress state and offer to resume from Phase 3 at the
   first non-completed workspace.
2. If the working files are absent, restart from Phase 0 but note that any previously created
   TFE workspaces may already exist — Phase 2 workspace-exists checks will surface them.
