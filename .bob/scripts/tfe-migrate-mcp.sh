#!/usr/bin/env bash
# tfe-migrate-mcp.sh — Simplified Terraform CE -> TFE Migration Assistant
#
# Focuses purely on migration execution:
#   1. Backs up local/remote state safely to .bob/tmp/tfe-migration-backups/
#   2. Stages and applies the TFE backend.tf (cloud block)
#   3. Initializes and pushes state (terraform init + state push)
#   4. Prepares migration audit log
#
# Note: Pre-flight checks & inventory are handled interactively by the Bob skill.
#
# Usage:
#   .bob/scripts/tfe-migrate-mcp.sh --dir <dir> --org <org> --workspace <ws> [--hostname <host>]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TMP_DIR="$WORKSPACE_ROOT/.bob/tmp"
mkdir -p "$TMP_DIR/tfe-migration-backups" "$TMP_DIR/tfe-backends"

DIR=""
ORG=""
WS=""
HOSTNAME_TFE="app.terraform.io"
YES=0

usage() {
  cat >&2 <<EOF
Usage: tfe-migrate-mcp.sh --dir <path> --org <tfe-org> --workspace <tfe-ws> [options]

Required:
  --dir <path>         Terraform workspace directory
  --org <name>         TFE organization
  --workspace <name>   TFE workspace name

Options:
  --hostname <host>    TFE hostname (default: app.terraform.io)
  --yes                Auto-approve confirmation gates
  -h, --help           Show help
EOF
}

die() { echo "ERROR: $1" >&2; exit "${2:-1}"; }
log() { echo "[tfe-migrate $(date -u +%H:%M:%S)] $*" >&2; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir)        DIR="${2:?}"; shift 2 ;;
    --org)        ORG="${2:?}"; shift 2 ;;
    --workspace)  WS="${2:?}"; shift 2 ;;
    --hostname)   HOSTNAME_TFE="${2:?}"; shift 2 ;;
    --yes)        YES=1; shift ;;
    -h|--help)    usage; exit 0 ;;
    *)            usage; die "Unknown argument: $1" 2 ;;
  esac
done

[[ -n "$DIR" && -n "$ORG" && -n "$WS" ]] || { usage; die "--dir, --org, and --workspace are required" 2; }
[[ -d "$DIR" ]] || die "Directory not found: $DIR" 2
ABS_DIR="$(cd "$DIR" && pwd)"
TS="$(date -u +%Y%m%d-%H%M%S)"

# ── Pre-migration Sanity Checks ──────────────────────────────────────────────
[[ -n "${TFE_TOKEN:-}" ]] || die "TFE_TOKEN environment variable is not set." 2

# Check for conflicting active backend blocks in other .tf files
for f in "$ABS_DIR"/*.tf; do
  [[ "$(basename "$f")" == "backend.tf" ]] && continue
  if grep -Eq '^[[:space:]]*backend[[:space:]]+"' "$f"; then
    die "$f contains an active backend block. Comment it out before migrating." 3
  fi
done

# 1. State Backup
log "Creating timestamped state backup..."
SRC_STATE="$ABS_DIR/terraform.tfstate"
BACKUP_STATE="$TMP_DIR/tfe-migration-backups/$WS-$TS.tfstate"

if [[ -s "$SRC_STATE" ]]; then
  cp "$SRC_STATE" "$BACKUP_STATE"
else
  log "No local terraform.tfstate found; attempting state pull from remote backend..."
  (cd "$ABS_DIR" && terraform state pull) > "$BACKUP_STATE" || die "Failed to capture state backup."
fi

[[ -s "$BACKUP_STATE" ]] || die "Backup state file is empty: $BACKUP_STATE"
log "State verified and backed up to: $BACKUP_STATE"

# Confirmation Gate
if [[ $YES -eq 0 ]]; then
  echo >&2
  echo "── CONFIRMATION GATE ──────────────────────────────────────────" >&2
  echo "Target Workspace : $WS (Org: $ORG @ $HOSTNAME_TFE)" >&2
  echo "Source Directory : $ABS_DIR" >&2
  echo "State Backup     : $BACKUP_STATE" >&2
  read -r -p "Apply TFE backend and push state? [y/N] " ans
  [[ "$ans" =~ ^[yY](es)?$ ]] || die "Migration aborted by user." 4
fi

# 2. Stage and Apply TFE backend.tf
log "Staging TFE cloud backend..."
STAGED_BACKEND="$TMP_DIR/tfe-backends/$WS-backend.tf"
cat > "$STAGED_BACKEND" <<EOF
terraform {
  cloud {
    hostname     = "$HOSTNAME_TFE"
    organization = "$ORG"

    workspaces {
      name = "$WS"
    }
  }
}
EOF

# Preserve original backend.tf if present
if [[ -f "$ABS_DIR/backend.tf" ]] && ! cmp -s "$ABS_DIR/backend.tf" "$STAGED_BACKEND"; then
  cp "$ABS_DIR/backend.tf" "$TMP_DIR/tfe-migration-backups/$WS-backend.tf.orig-$TS"
fi
cp "$STAGED_BACKEND" "$ABS_DIR/backend.tf"

# 3. Initialize & Push State
log "Initializing HCP Terraform / TFE cloud integration..."
export TF_TOKEN_$(echo "$HOSTNAME_TFE" | sed -e 's/-/__/g' -e 's/\./_/g')="${TFE_TOKEN:-}"

# When migrating backend, terraform init prompts to copy existing state to the new backend.
# We pass interactive input or pipe 'yes' to allow Terraform to complete backend migration.
(cd "$ABS_DIR" && echo "yes" | terraform init) || die "terraform init failed."

# If state was not automatically migrated during init, push backup state
if (cd "$ABS_DIR" && ! terraform state list >/dev/null 2>&1); then
  log "Pushing backup state to TFE workspace $WS..."
  (cd "$ABS_DIR" && terraform state push "$BACKUP_STATE") || die "terraform state push failed."
fi

log "State migration completed successfully for $WS."
