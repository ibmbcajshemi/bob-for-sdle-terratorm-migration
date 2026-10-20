# Rule: Morgan Stanley Workspace Naming and Secret Isolation Standards

Applies to: `tfe-migration` mode, `tfe-migration-assistant` skill.

Every TFE workspace created during migration must comply with the MS naming schema and
secret isolation model. Non-compliant workspaces will be rejected by the platform team's
policy engine at plan time. Enforce these rules at GATE-2, before any workspace is created.

---

## Workspace Naming Schema

### Pattern

```
<team>-<environment>-<service>
```

All lowercase. Segments separated by single hyphens. No underscores, dots, or slashes.
Maximum total length: 64 characters (TFE API hard limit).

| Segment | Description | Allowed Values |
|---|---|---|
| `<team>` | Owning team identifier — matches the team's AD group short-name | 2–20 chars, `[a-z0-9-]+` |
| `<environment>` | Deployment tier | `dev`, `uat`, `staging`, `prod` |
| `<service>` | Service or component name — matches the service catalogue entry | 2–30 chars, `[a-z0-9-]+` |

### Examples

| CE Directory | Derived TFE Name | Valid? |
|---|---|---|
| `payments/prod/billing-api` | `payments-prod-billing-api` | ✅ |
| `risk/uat/market-data` | `risk-uat-market-data` | ✅ |
| `Infra/DEV/mySQL_DB` | — | ❌ (uppercase, underscore — must be corrected) |
| `platform-prod` | — | ❌ (missing service segment) |
| `fx-staging-rates-engine-v2-replatform-migration-wip-2024` | — | ❌ (exceeds 64 chars) |

### Validation (enforce at GATE-2)

Before accepting a workspace name — whether auto-derived or user-supplied — validate it:

```bash
validate_ws_name() {
  local name="$1"
  # Must match <team>-<env>-<service> with exactly 2 hyphens minimum (3 segments)
  if [[ ! "$name" =~ ^[a-z0-9]+(-[a-z0-9]+)+-[a-z0-9]+$ ]]; then
    echo "INVALID: does not match <team>-<environment>-<service> pattern"
    return 1
  fi
  # Environment segment must be one of the approved values
  local env_seg
  env_seg=$(echo "$name" | cut -d'-' -f2)
  if [[ ! "$env_seg" =~ ^(dev|uat|staging|prod)$ ]]; then
    echo "INVALID: environment segment '$env_seg' not in [dev, uat, staging, prod]"
    return 1
  fi
  # Length check
  if [[ ${#name} -gt 64 ]]; then
    echo "INVALID: name length ${#name} exceeds 64 characters"
    return 1
  fi
  echo "VALID"
}
```

If a name fails validation, do not create the workspace. Present the specific failure reason
and ask the user to provide a corrected name. Re-validate before proceeding.

### Auto-derivation from CE Directory

When deriving the TFE workspace name from a CE directory path:

1. Take the last three path segments: `team/environment/service`.
2. Lowercase all characters.
3. Replace any character not in `[a-z0-9-]` with `-`.
4. Collapse consecutive hyphens to a single `-`.
5. Strip leading/trailing hyphens from each segment.
6. Validate the result. If it fails (e.g. the CE path does not have 3 meaningful segments),
   present the auto-derived candidate and ask the user to confirm or correct it before GATE-2.

---

## Secret Isolation Standard: Vault-backed TFE Variable Sets

### Policy

**No secret or credential value may be stored as a plain TFE workspace variable.**
All secrets must be sourced from Vault and surfaced to TFE workspaces via a
**Vault-backed TFE Variable Set** attached at the workspace level.

"Secret" is defined as any value matching one or more of the following:
- Variable name contains: `password`, `secret`, `token`, `key`, `api_key`, `private_key`,
  `credential`, `cert`, `pass`, `pat`, `client_secret`, `access_key`, `secret_key`
- Value is a string with entropy > 3.5 bits/char (heuristic for generated secrets)
- Variable was flagged `sensitive: true` in CE or marked in the Phase 1 inventory

### Variable Set Naming Convention

```
vs-<team>-<environment>-<purpose>
```

Examples: `vs-payments-prod-aws-creds`, `vs-risk-uat-db-passwords`

### Vault Integration Architecture

Variables are not injected directly. The flow is:

```
HashiCorp Vault (MS internal)
    └─ KV secret path: secret/tfe/<team>/<environment>/<service>/<variable-name>
         ↓  (Vault Agent or TFE Vault-backed Variable Set sync)
TFE Variable Set: vs-<team>-<environment>-<purpose>
    └─ Attached to workspace: <team>-<environment>-<service>
         ↓
Terraform run (variable available as TF_VAR_* or provider env var)
```

### Migration Assistant Responsibilities

During Phase 2, for each secret variable identified in the Phase 1 inventory:

1. **Do not upload the secret value to TFE.** Skip it from the variable upload step entirely.
2. Surface a warning in the Phase 2 creation summary:
   > "⚠️ SECRET EXCLUDED: Variable `{variable-name}` in workspace `{workspace-name}` was not
   > uploaded. It must be migrated to Vault at path:
   > `secret/tfe/{team}/{environment}/{service}/{variable-name}`
   > and attached via a Variable Set before this workspace can plan successfully."
3. Generate a Vault migration checklist section in `tfe-migration-report.md`:

   ```markdown
   ## Vault Secret Migration Checklist

   The following variables must be written to Vault and attached via Variable Sets
   before the listed workspaces can run plans successfully.

   | Workspace | Variable Name | Vault Path | Variable Set Name | Status |
   |---|---|---|---|---|
   | payments-prod-billing-api | db_password | secret/tfe/payments/prod/billing-api/db_password | vs-payments-prod-db-passwords | ☐ |
   ```

4. Do not mark a workspace ✅ MIGRATED in Phase 4 if it has outstanding Vault items
   in the checklist. Mark it ⚠️ SECRETS PENDING instead.

### Existing Plain-text Secrets in CE `.tfvars`

If the Phase 1 inventory detected a sensitive variable with a **literal value** in a
`.tfvars` file (not a variable reference):

1. Flag it ❌ BLOCKED in the inventory — it must not be migrated as-is.
2. Instruct the user:
   > "Variable `{name}` in `{file}` contains a literal secret value. Before this workspace
   > can be migrated: (1) rotate the secret, (2) write the new value to Vault at the path
   > above, (3) remove the literal value from the `.tfvars` file and replace it with a
   > reference or leave it to be sourced from the Variable Set."
3. Only unblock the workspace after the user confirms the above steps are complete.

### Variable Sets That Apply Across Environments

Some Variable Sets are scoped to an entire team across all environments
(e.g. shared AWS IAM role ARNs). Name these:

```
vs-<team>-global-<purpose>
```

Example: `vs-platform-global-tfe-agent-token`

These are attached to all workspaces for the team and must not contain
environment-specific values. If a global Variable Set is needed, surface it in the
Vault migration checklist and mark it for platform team review before attachment.

---

## TFE Variable Set API Reference

Attach a Variable Set to a workspace (use this in Phase 2 post-workspace-creation):

```bash
# Get Variable Set ID by name
VS_ID=$(curl -s \
  --header "Authorization: Bearer $TFE_TOKEN" \
  "https://$TFE_HOSTNAME/api/v2/organizations/$TFE_ORG/varsets?filter[name]=vs-{name}" \
  | jq -r '.data[0].id // "null"')

# Attach Variable Set to workspace
curl -s --request POST \
  --header "Authorization: Bearer $TFE_TOKEN" \
  --header "Content-Type: application/vnd.api+json" \
  --data "{\"data\":[{\"type\":\"workspaces\",\"id\":\"{workspace-id}\"}]}" \
  "https://$TFE_HOSTNAME/api/v2/varsets/$VS_ID/relationships/workspaces"
```

If `VS_ID` is `null` (Variable Set does not yet exist), do not create it — Variable Sets
are managed by the platform team. Log it as a SECRETS PENDING item in the report and
surface the creation request to the platform team.
