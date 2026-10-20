# Project Architecture Rules (Non-Obvious Only)
- Migration is strictly linear Phase 0→4 with hard human gates (GATE-0..4); no skipping/merging phases. Gate prompts use `ask_followup_question`.
- State flow: COS S3 backend → local backup in `/tmp/tfe-migration-backups/` → locked TFE workspace → `state push` (never `-force`). A TFE serial higher than local = halt and escalate.
- New TFE workspaces reset state serial to 1; a CE-vs-TFE serial mismatch is expected there, verify via resource count and `plan` exit code 0.
- `bootstrap/` (state bucket) is excluded from migration by design; it must exist before any COS-backed environment.
- Platform team owns Variable Sets, team access, notifications, VCS connections — do not plan those into migration steps.
