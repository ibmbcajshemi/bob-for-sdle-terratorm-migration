# TFE Migration Rules
# Applies when the tfe-migration mode is active or the tfe-migration-assistant skill is loaded.
# These rules encode the MS Terraform platform team's non-negotiable migration constraints.

## Safety Invariants (never violate, no exceptions)

- **Never delete or overwrite a state file without a timestamped backup existing at
  `/tmp/tfe-migration-backups/{workspace-name}-{YYYYMMDD-HHMMSS}.tfstate`.**
- **Never use `terraform state push -force`.** Serial conflicts must be escalated to the platform
  team, not bypassed.
- **Never print raw TFE API token values.** Reference tokens only as `$TFE_TOKEN` or the
  user-supplied variable name.
- **Never migrate a workspace flagged ❌ BLOCKED in Phase 1** without the user explicitly
  resolving the blocking issue and re-running the inventory.
- **Always lock a TFE workspace before pushing state and unlock after confirmation.**

## Confirmation Gates (require explicit user confirmation before proceeding)

- Before creating any TFE workspace via API.
- Before uploading any Terraform variables (especially those marked sensitive).
- Before running `terraform state push` on any workspace.
- Before switching a TFE workspace execution mode from `local` to `remote`.
- Before archiving or deleting any working files in `/tmp/tfe-migration-*`.

## Naming Conventions

- TFE workspace names are derived from the CE directory basename with non-alphanumeric characters
  replaced by `-` and lowercased. Example: `infra/prod-us-east` → `prod-us-east`.
- Backup files use the pattern: `{workspace-basename}-{YYYYMMDD-HHMMSS}.tfstate`.
- The migration report file is always written to `{PROJECT_ROOT}/tfe-migration-report.md`.

## Scope Constraints

- Only migrate workspaces from the `$PROJECT_ROOT` the user confirmed in Phase 0.
- Do not modify any `.tf` source files directly during migration — only `backend.tf` files staged
  to `/tmp/tfe-backends/` are created. The user applies them explicitly in Phase 3.
- Do not create TFE workspace-level notification configurations, team access settings, or
  VCS connections during migration — those are platform team responsibilities post-migration.

## Error Handling

- Any TFE API response with HTTP status >= 400 must be surfaced verbatim. Do not retry
  automatically — surface the error and ask the user how to proceed.
- Any `terraform` command that exits non-zero must halt the current workspace's migration.
  Log the failure to the migration report and move to the next workspace only if the user
  explicitly requests it.
- If `jq` cannot parse a state file or API response, treat it as a blocking error.

## Working File Locations (do not change without platform team approval)

| Artifact                    | Path                                          |
|-----------------------------|-----------------------------------------------|
| Inventory JSON              | `/tmp/tfe-migration-inventory.json`           |
| Confirmed workspace list    | `/tmp/tfe-migration-confirmed.json`           |
| State backups               | `/tmp/tfe-migration-backups/`                 |
| Staged backend configs      | `/tmp/tfe-backends/{workspace-name}/backend.tf` |
| Completed workspace log     | `/tmp/tfe-migration-completed.txt`            |
| Validation report JSON      | `/tmp/tfe-migration-validation.json`          |
| Final migration report (MD) | `{PROJECT_ROOT}/tfe-migration-report.md`      |

## TFE API Version

Use TFE API v2 (`/api/v2/`) exclusively. Do not use any TFE API v1 or undocumented endpoints.

## Rollback Procedure (surface these instructions for any FAILED workspace)

```bash
# 1. Restore the CE state backup
cp /tmp/tfe-migration-backups/{workspace-name}-{timestamp}.tfstate \
   {workspace-dir}/terraform.tfstate

# 2. Remove the TFE backend file that was applied
rm -f {workspace-dir}/backend.tf

# 3. Re-initialize with the original local backend
cd {workspace-dir} && terraform init -reconfigure

# 4. Verify local state is intact
terraform state list

# 5. (Optional) Delete the partially-created TFE workspace
curl -s --request DELETE \
  --header "Authorization: Bearer $TFE_TOKEN" \
  "https://$TFE_HOSTNAME/api/v2/workspaces/{workspace-id}"
```
