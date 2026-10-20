# Project Coding Rules (Non-Obvious Only)
- Do not modify `.tf` source files during a migration session; only stage `backend.tf` under `/tmp/tfe-backends/{ws}/` (user applies it in Phase 3).
- Any new `ibmcloud-infra` resource must follow the `${var.project_name}-${var.environment}-<type>` name pattern and carry the three standard tags (see `ibmcloud-infra/main.tf`).
- Never put credentials in `.tf`/`.tfvars`; `ibmcloud_api_key`, `ssh_public_key`, HMAC keys are runtime-only (`TF_VAR_*`).
- `ibmcloud-infra/backend.tf` (TFE `cloud` block) and the commented S3 backend in `versions.tf` are mutually exclusive.
- `.bob/mcp.json` holds a plaintext TFE token — do not echo it; never write tokens into new files.
- Rollback for a failed workspace: restore backup, delete `backend.tf`, `terraform init -reconfigure` (full steps in `.bob/rules/tfe-migration.md`).
