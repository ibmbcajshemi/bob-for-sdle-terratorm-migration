# AGENTS.md

This file provides guidance to agents when working with code in this repository.

## Layout (two nested git repos)
- Workspace root = Bob migration tooling (`.bob/`: custom mode `tfe-migration`, rules, skill, scripts) + CE→TFE notes.
- `ibmcloud-infra/` = separate git repo (own `.git`), Terraform for IBM Cloud (COS, VPC, VSI, Code Engine). Commit changes there, not from the root repo.
- `ibmcloud-infra/bootstrap/` = one-time local-backend project creating the COS state bucket. Intentionally NOT migrated to TFE.

## Commands (no test suite, no lint config exists)
- Validate: `cd ibmcloud-infra && terraform fmt -check && terraform validate`
- Plan: `terraform plan -var-file=environments/dev.tfvars -var="ssh_public_key=$(cat ~/.ssh/id_rsa.pub)"` (`app_bucket_name` and `ssh_public_key` have no defaults; `ibmcloud_api_key` via `TF_VAR_ibmcloud_api_key`).
- Env: `cp .env.example .env && set -a && source .env && set +a`. `AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY` hold IBM COS HMAC keys, not AWS keys.
- Migration scripts (run via `bash`, never re-implement their logic):
  `bash .bob/skills/tfe-migration-assistant/preflight-inventory.sh --root <path> --output /tmp/tfe-migration-inventory.json`
  `bash .bob/skills/tfe-migration-assistant/post-migration-validate.sh --inventory ... --completed ... --tfe-hostname ... --tfe-org ... --output ...` (flags documented in script header).

## Non-obvious gotchas
- Backend state: `ibmcloud-infra/backend.tf` is now a `cloud {}` block (org `tce-to-tfe-migration`, workspace `ajs-dev-ibmcloud-infra`); the old S3/COS backend in `versions.tf` is commented out. Never enable both — `terraform init` fails with conflicting backends.
- The TFE workspace is dev-only; there is no prod workspace. `environments/*.tfvars` are gitignored (`*.tfvars` in `.gitignore`) yet exist locally — don't expect them in git.
- `*.lock.hcl` and `*.tfstate*` are gitignored; never commit them, and never edit state files by hand.
- Resource convention in `main.tf`: names `${var.project_name}-${var.environment}-<type>`; every taggable resource carries the three tags `environment:`, `managed-by:terraform`, `project:`. Prod-only behaviour is gated on `var.environment == "prod"` / `enable_versioning`.
- `variables.tf` sections use `# ====` banner comments; every variable has `type` + `description`; secrets are `sensitive = true`. Keep `validation` blocks for enumerated values (`environment`, `app_storage_class`).
- `.bob/mcp.json` contains a hardcoded `TFE_TOKEN`. Never print, copy, or commit it; prefer `.bob/scripts/run-terraform-mcp.sh` (reads `$TFE_TOKEN` from env) and flag the leak to the user.
- `.bob/rules/tfe-migration.md` and `.bob/rules-tfe-migration/*.md` are authoritative for migration work: 4 phases with human gates (GATE-0..4), timestamped backups at `/tmp/tfe-migration-backups/{ws}-{YYYYMMDD-HHMMSS}.tfstate` before any state mutation, never `state push -force`, lock workspace before push.
- TFE workspace names must match `<team>-<dev|uat|staging|prod>-<service>`, lowercase, ≤64 chars. Secrets must not be uploaded as TFE variables (Vault-backed Variable Sets only).
- Use TFE API v2 only; surface any HTTP ≥400 verbatim, no auto-retry.
