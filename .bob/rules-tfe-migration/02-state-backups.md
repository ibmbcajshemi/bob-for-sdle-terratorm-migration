# Rule: Mandatory Timestamped State Backups

Applies to: `tfe-migration` mode, `tfe-migration-assistant` skill.

State files are the single source of truth for every Terraform-managed resource.
Any corruption, accidental overwrite, or serial conflict is unrecoverable without a backup.
This rule defines the exact backup protocol — no deviation is permitted.

---

## Backup Invariants

1. **A backup must exist and be verified before any state-mutating operation.**
   "State-mutating operation" means any of:
   - `terraform state push`
   - `terraform state mv`
   - `terraform state rm`
   - `terraform state replace-provider`
   - Any TFE API call that creates or uploads a new state version
     (`POST /api/v2/workspaces/{id}/state-versions`)

2. **Never proceed if the backup file cannot be verified.** Verification means:
   - The file exists at the expected path.
   - `jq '.serial' {backup-file}` returns a non-null integer.
   - The file size is greater than zero bytes.
   If any check fails, halt and surface the error — do not attempt the state operation.

3. **Backups are write-once.** Never overwrite an existing backup file.
   If a file already exists at the target path (e.g. from a prior interrupted run),
   choose a new timestamp suffix rather than clobbering it.

4. **Backups must be retained for the duration of the session.** Do not delete or move
   backup files until GATE-4 is cleared and the user explicitly approves archival.

---

## Backup Path Convention

```
/tmp/tfe-migration-backups/{workspace-name}-{YYYYMMDD-HHMMSS}.tfstate
```

| Token | Value |
|---|---|
| `{workspace-name}` | The TFE workspace name derived in Phase 2 (e.g. `payments-prod-billing`) |
| `{YYYYMMDD-HHMMSS}` | UTC timestamp at backup creation time (e.g. `20240315-143022`) |

Example:
```
/tmp/tfe-migration-backups/payments-prod-billing-20240315-143022.tfstate
```

The backup directory must be created if it does not exist:
```bash
mkdir -p /tmp/tfe-migration-backups
```

---

## Backup Procedure (run this exact sequence)

Execute as a single atomic block before any state-mutating operation:

```bash
# Step 1 — resolve source state file
STATE_SRC="{workspace-dir}/terraform.tfstate"
WS_NAME="{workspace-name}"
TIMESTAMP=$(date -u +%Y%m%d-%H%M%S)
BACKUP_DIR="/tmp/tfe-migration-backups"
BACKUP_PATH="${BACKUP_DIR}/${WS_NAME}-${TIMESTAMP}.tfstate"

# Step 2 — create backup directory
mkdir -p "$BACKUP_DIR"

# Step 3 — copy state file
cp "$STATE_SRC" "$BACKUP_PATH"

# Step 4 — verify backup integrity
if [[ ! -s "$BACKUP_PATH" ]]; then
  echo "ERROR: backup file is empty: $BACKUP_PATH" >&2
  exit 1
fi
SERIAL=$(jq -r '.serial // empty' "$BACKUP_PATH")
if [[ -z "$SERIAL" ]]; then
  echo "ERROR: backup has no serial: $BACKUP_PATH" >&2
  exit 1
fi

echo "Backup verified: $BACKUP_PATH (serial=$SERIAL)"
```

Surface the echoed confirmation line in chat before proceeding to the state operation.

---

## Backup Record in Migration Report

Every backup created must be logged in `{PROJECT_ROOT}/tfe-migration-report.md` with:

```
| {workspace-name} | {backup-path} | {serial} | {UTC timestamp} | verified |
```

If a backup cannot be created (e.g. source state file missing), the workspace must be
marked ❌ BLOCKED and its migration halted. Log the reason in the report.

---

## Multiple State Operations on the Same Workspace

If a workspace requires more than one state-mutating operation in the same session
(e.g. `state mv` followed by `state push`), take a **fresh backup** before each operation.
Do not reuse a backup taken for a prior operation in the same session.

---

## Backup Archival (Post GATE-4)

After GATE-4 is cleared, ask the user:
> "Migration complete. Where should the state backups be archived?
> Options: (a) Leave in /tmp (will be lost on reboot), (b) Copy to a path you specify,
> (c) Upload to the team's designated S3/GCS backup bucket."

If the user selects (b) or (c), perform the copy/upload and confirm each file.
Do not delete the originals from `/tmp` until the archive is confirmed.

If the user selects (a) or does not respond, warn:
> "⚠️ Backups remain in /tmp and will be lost on system restart.
> The platform team recommends archiving to a durable store."

---

## Conflict: TFE State Serial Higher Than Local

If at any point the TFE workspace's current state serial is **higher** than the local backup serial:

1. **Halt immediately.** Do not push local state — doing so would roll back TFE state.
2. Surface this message:
   > "❌ SERIAL CONFLICT: TFE serial ({tfe_serial}) > local backup serial ({ce_serial}).
   > This means TFE state is ahead of the local copy. Pushing local state would destroy
   > TFE-side changes. This must be resolved by the platform team before migration continues."
3. Unlock the TFE workspace if it is currently locked.
4. Do not proceed with this workspace until the platform team explicitly instructs otherwise
   in writing (captured in the migration report).
