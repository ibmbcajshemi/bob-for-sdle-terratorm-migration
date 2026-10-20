#!/usr/bin/env zsh
# Ensure standard system paths are available in non-interactive zsh
export PATH="/usr/bin:/usr/local/bin:/opt/homebrew/bin:$PATH"
# preflight-inventory.sh
# Scans a Terraform CE project root and emits a structured JSON inventory
# of every workspace found, including backend type, provider versions,
# Terraform version, .tfvars sensitivity flags, and remote-state references.
#
# Usage:
#   bash preflight-inventory.sh --root <path> --output <output.json>
#
# Output schema (JSON array of workspace objects):
#   {
#     "dir": "/abs/path/to/workspace",
#     "name": "workspace-name",
#     "terraform_version": "1.5.0" | null,
#     "backend_type": "local" | "remote" | "s3" | "gcs" | ... | "none",
#     "provider_count": 3,
#     "providers_pinned": true | false,
#     "remote_state_refs": ["module.vpc", ...],
#     "tfvars_files": ["terraform.tfvars", ...],
#     "sensitive_variable_suspects": ["db_password", ...],
#     "lock_file_age_seconds": 42 | null,
#     "issues": [
#       {"level": "error"|"warning", "code": "...", "message": "..."}
#     ]
#   }

set -euo pipefail

ROOT=""
OUTPUT=""

# ── Argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --root)    ROOT="$2";   shift 2 ;;
    --output)  OUTPUT="$2"; shift 2 ;;
    *)         echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "$ROOT" || -z "$OUTPUT" ]]; then
  echo "Usage: $0 --root <path> --output <output.json>" >&2
  exit 1
fi

ROOT="$(cd "$ROOT" && pwd)"
RESULTS="[]"

# ── Helpers ───────────────────────────────────────────────────────────────────
json_str()  { printf '%s' "$1" | jq -Rs '.'; }
json_bool() { [[ "$1" == "true" ]] && echo "true" || echo "false"; }

extract_terraform_version() {
  local dir="$1"
  # Check .terraform-version (tfenv)
  if [[ -f "$dir/.terraform-version" ]]; then
    cat "$dir/.terraform-version" | tr -d '[:space:]'
    return
  fi
  # Check required_version in .tf files
  local ver
  ver=$(grep -rh 'required_version' "$dir"/*.tf 2>/dev/null \
        | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1 || true)
  echo "${ver:-null-raw}"
}

extract_backend_type() {
  local dir="$1"
  local backend
  # Search all .tf files for backend block
  backend=$(grep -rh 'backend\s*"' "$dir"/*.tf 2>/dev/null \
            | grep -oE 'backend\s*"[^"]+"' \
            | grep -oE '"[^"]+"' \
            | tr -d '"' | head -1 || true)
  if [[ -z "$backend" ]]; then
    # Check for terraform { backend {} } without type
    if grep -qrh 'backend\s*{' "$dir"/*.tf 2>/dev/null; then
      echo "local"
    else
      echo "none"
    fi
  else
    echo "$backend"
  fi
}

count_providers() {
  local dir="$1"
  grep -rh 'source\s*=' "$dir"/*.tf 2>/dev/null \
    | grep -c 'registry.terraform.io\|hashicorp/' || true
}

providers_pinned() {
  local dir="$1"
  # Pinned means required_providers block exists with version constraints
  if grep -qrh 'required_providers' "$dir"/*.tf 2>/dev/null; then
    echo "true"
  else
    echo "false"
  fi
}

find_remote_state_refs() {
  local dir="$1"
  # Find terraform_remote_state data sources
  grep -rh 'data\s*"terraform_remote_state"' "$dir"/*.tf 2>/dev/null \
    | grep -oE '"[^"]+"' | sed 's/"//g' | sort -u | tr '\n' ',' \
    | sed 's/,$//' || true
}

find_tfvars_files() {
  local dir="$1"
  find "$dir" -maxdepth 1 -name '*.tfvars' -o -name '*.tfvars.json' 2>/dev/null \
    | xargs -I{} basename {} | tr '\n' ',' | sed 's/,$//' || true
}

find_sensitive_suspects() {
  local dir="$1"
  # Look for variable names that suggest sensitive data with literal string values
  grep -rh -A3 'variable\s*"' "$dir"/*.tf 2>/dev/null \
    | grep -oE '"(password|secret|token|key|api_key|private_key|credential|cert|pass)[^"]*"' \
    | tr -d '"' | sort -u | tr '\n' ',' | sed 's/,$//' || true
  # Also scan .tfvars for bare sensitive-looking assignments
  grep -rh -E '(password|secret|token|api_key|private_key|credential)\s*=' \
    "$dir"/*.tfvars "$dir"/*.tfvars.json 2>/dev/null \
    | grep -oE '^[a-z_]+' | sort -u | tr '\n' ',' | sed 's/,$//' || true
}

lock_file_age() {
  local dir="$1"
  local lockfile="$dir/.terraform.lock.hcl"
  if [[ -f "$lockfile" ]]; then
    local mtime now
    mtime=$(stat -f '%m' "$lockfile" 2>/dev/null || stat -c '%Y' "$lockfile" 2>/dev/null || echo 0)
    now=$(date +%s)
    echo $(( now - mtime ))
  else
    echo "null"
  fi
}

# ── Main scan ─────────────────────────────────────────────────────────────────
# Find directories that contain at least one .tf file
WORKSPACE_DIRS=("${(@f)$(
  find "$ROOT" -type f -name '*.tf' \
    ! -path '*/.terraform/*' \
    ! -path '*/modules/*' \
    | xargs -I{} dirname {} | sort -u
)}")

if [[ ${#WORKSPACE_DIRS[@]} -eq 0 ]]; then
  echo "[]" > "$OUTPUT"
  echo "No Terraform workspaces found under $ROOT" >&2
  exit 0
fi

for DIR in "${WORKSPACE_DIRS[@]}"; do
  NAME="$(basename "$DIR")"
  ISSUES="[]"

  # Terraform version
  RAW_VER="$(extract_terraform_version "$DIR")"
  if [[ "$RAW_VER" == "null-raw" ]]; then
    TF_VERSION="null"
    ISSUES=$(echo "$ISSUES" | jq '. + [{"level":"warning","code":"NO_TF_VERSION","message":"No terraform version constraint or .terraform-version file found"}]')
  else
    TF_VERSION=$(json_str "$RAW_VER")
    # Check semver major.minor
    MAJOR=$(echo "$RAW_VER" | cut -d. -f1)
    MINOR=$(echo "$RAW_VER" | cut -d. -f2)
    if [[ "$MAJOR" -eq 0 && "$MINOR" -lt 13 ]]; then
      ISSUES=$(echo "$ISSUES" | jq '. + [{"level":"error","code":"TF_VERSION_TOO_OLD","message":"Terraform version '"$RAW_VER"' < 0.13; state format upgrade required before migration"}]')
    fi
  fi

  # Backend type
  BACKEND="$(extract_backend_type "$DIR")"
  if [[ "$BACKEND" != "local" && "$BACKEND" != "remote" && "$BACKEND" != "none" ]]; then
    ISSUES=$(echo "$ISSUES" | jq ". + [{\"level\":\"error\",\"code\":\"NON_LOCAL_BACKEND\",\"message\":\"Backend type '$BACKEND' must be swapped to 'local' or 'remote' before TFE migration\"}]")
  fi

  # Providers
  PROVIDER_COUNT="$(count_providers "$DIR")"
  PINNED="$(providers_pinned "$DIR")"
  if [[ "$PINNED" == "false" ]]; then
    ISSUES=$(echo "$ISSUES" | jq '. + [{"level":"warning","code":"PROVIDERS_UNPINNED","message":"No required_providers block found; provider versions are not pinned"}]')
  fi

  # Remote state refs
  REMOTE_STATE_CSV="$(find_remote_state_refs "$DIR")"
  if [[ -n "$REMOTE_STATE_CSV" ]]; then
    ISSUES=$(echo "$ISSUES" | jq ". + [{\"level\":\"warning\",\"code\":\"REMOTE_STATE_REFS\",\"message\":\"terraform_remote_state references found ($REMOTE_STATE_CSV); these must be re-pointed after migration\"}]")
  fi

  # .tfvars
  TFVARS_CSV="$(find_tfvars_files "$DIR")"

  # Sensitive suspects
  SENSITIVE_CSV="$(find_sensitive_suspects "$DIR")"
  if [[ -n "$SENSITIVE_CSV" ]]; then
    ISSUES=$(echo "$ISSUES" | jq ". + [{\"level\":\"warning\",\"code\":\"SENSITIVE_VARS\",\"message\":\"Potentially sensitive variables found: $SENSITIVE_CSV\"}]")
  fi

  # Lock file age
  LOCK_AGE="$(lock_file_age "$DIR")"
  if [[ "$LOCK_AGE" != "null" && "$LOCK_AGE" -lt 300 ]]; then
    ISSUES=$(echo "$ISSUES" | jq ". + [{\"level\":\"error\",\"code\":\"ACTIVE_LOCK\",\"message\":\".terraform.lock.hcl modified ${LOCK_AGE}s ago — workspace may have an active run\"}]")
  fi

  # Build workspace JSON object
  WS_JSON=$(jq -n \
    --arg  dir        "$DIR" \
    --arg  name       "$NAME" \
    --argjson tf_ver  "${TF_VERSION:-null}" \
    --arg  backend    "$BACKEND" \
    --argjson prov_ct "${PROVIDER_COUNT:-0}" \
    --argjson pinned  "$PINNED" \
    --arg  rs_refs    "$REMOTE_STATE_CSV" \
    --arg  tfvars     "$TFVARS_CSV" \
    --arg  sensitive  "$SENSITIVE_CSV" \
    --argjson lock    "${LOCK_AGE}" \
    --argjson issues  "$ISSUES" \
    '{
      dir:                      $dir,
      name:                     $name,
      terraform_version:        $tf_ver,
      backend_type:             $backend,
      provider_count:           $prov_ct,
      providers_pinned:         $pinned,
      remote_state_refs:        ($rs_refs | split(",") | map(select(length > 0))),
      tfvars_files:             ($tfvars   | split(",") | map(select(length > 0))),
      sensitive_variable_suspects: ($sensitive | split(",") | map(select(length > 0))),
      lock_file_age_seconds:    $lock,
      issues:                   $issues
    }'
  )

  RESULTS=$(echo "$RESULTS" | jq ". + [$WS_JSON]")
done

echo "$RESULTS" | jq '.' > "$OUTPUT"
echo "Inventory written to $OUTPUT ($(echo "$RESULTS" | jq 'length') workspaces)" >&2
