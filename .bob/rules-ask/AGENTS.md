# Project Documentation Rules (Non-Obvious Only)
- Two git repos: workspace root (Bob tooling) and `ibmcloud-infra/` (Terraform; has its own `.git`).
- `ibmcloud-infra/README.md` still describes the COS S3 backend flow; the live backend is now TFE (`backend.tf`). `tfe-migration-report.md` is the record of that migration.
- `Terraform_CE_to_TFE_general_and_code_changes_MS_notes.md` (root) is the general CE→TFE background reference.
- Migration rules live in two places: `.bob/rules/tfe-migration.md` (invariants) and `.bob/rules-tfe-migration/01-03*.md` (gates, backups, naming/secrets, mode-scoped).
- "MS" in docs/rules = Morgan Stanley platform team standards.
