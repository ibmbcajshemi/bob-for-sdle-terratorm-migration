#!/usr/bin/env zsh
# Ensure standard system paths are available in non-interactive zsh
export PATH="/usr/bin:/usr/local/bin:/opt/homebrew/bin:$PATH"
# post-migration-validate.sh
# Cross-checks the TFE workspace state against the pre-migration CE backup
# for every workspace in the confirmed migration list.
# Also triggers a terraform plan (no-op check) per workspace and captures drift.
#
# Usage:
#   bash post-migration-validate.sh \
#     --inventory   /tmp/tfe-migration-confirmed.json \
#     --completed   /tmp/tfe-migration-completed.txt \
#     --tfe-hostname tfe.example.com \
#     --tfe-org      my-org \
#     --output       /tmp/tfe-migration-validation.json
#
# Requires: curl, jq, terraform (in PATH), $TFE_TOKEN in environment
#
# Output schema (JSON array of validation result objects):
#   {
#     "workspace": "my-workspace",
#     "dir": "/abs/path",
#     "tfe_workspace_id": "ws-xxxx",
#     "ce_state_serial": 12,
#     "tfe_state_serial": 12,
#     "serials_match": true,
#     "plan_exit_code": 0,
#     "plan_output_snippet": "No changes. ...",
#     "drift_detected": false,
#     "status": "MIGRATED" | "DRIFT" | "SERIAL_MISMATCH" | "PLAN_FAILED" | "SKIPPED",
#     "errors": []
#   }

set -euo pipefail

INVENTORY=""
COMPLETED=""
TFE_HOSTNAME=""
TFE_ORG=""
OUTPUT=""

# ── Argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --inventory)    INVENTORY="$2";    shift 2 ;;
    --completed)    COMPLETED="$2";    shift 2 ;;
    --tfe-hostname) TFE_HOSTNAME="$2"; shift 2 ;;
    --tfe-org)      TFE_ORG="$2";      shift 2 ;;
    --output)       OUTPUT="$2";       shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

for VAR in INVENTORY COMPLETED TFE_HOSTNAME TFE_ORG OUTPUT; do
  if [[ -z "${(P)VAR}" ]]; then
    echo "Missing required argument: --$(echo "$VAR" | tr '[:upper:]' '[:lower:]' | tr '_' '-')" >&2
    exit 1
  fi
done

if [[ -z "${TFE_TOKEN:-}" ]]; then
  echo "ERROR: \$TFE_TOKEN environment variable is not set." >&2
  exit 1
fi

# ── Helpers ───────────────────────────────────────────────────────────────────
tfe_get() {
  local path="$1"
  /usr/bin/curl -sf \
    --header "Authorization: Bearer $TFE_TOKEN" \
    --header "Content-Type: application/vnd.api+json" \
    "https://$TFE_HOSTNAME/api/v2/$path"
}

get_tfe_workspace_id() {
  local ws_name="$1"
  tfe_get "organizations/$TFE_ORG/workspaces/$ws_name" \
    | jq -r '.data.id // "null"'
}

get_tfe_state_serial() {
  local ws_id="$1"
  tfe_get "workspaces/$ws_id/current-state-version" \
    | jq -r '.data.attributes.serial // "null"'
}

get_ce_state_serial() {
  local dir="$1"
  local backup_pattern="/tmp/tfe-migration-backups/$(basename "$dir")-*.tfstate"
  # Use the most recent backup
  local latest
  latest=$(ls -t $backup_pattern 2>/dev/null | head -1 || true)
  if [[ -z "$latest" ]]; then
    # Fall back to current state in workspace dir
    latest="$dir/terraform.tfstate"
  fi
  if [[ -f "$latest" ]]; then
    jq -r '.serial // "null"' "$latest"
  else
    echo "null"
  fi
}

run_plan_check() {
  local dir="$1"
  local plan_output
  local exit_code=0
  # Run plan with -detailed-exitcode:
  #   0 = no changes, 1 = error, 2 = changes present
  plan_output=$(cd "$dir" && terraform plan -detailed-exitcode -no-color 2>&1) || exit_code=$?
  echo "$exit_code|$plan_output"
}

# ── Load completed workspace names ────────────────────────────────────────────
if [[ ! -f "$COMPLETED" ]]; then
  echo "ERROR: completed file not found: $COMPLETED" >&2
  exit 1
fi
COMPLETED_NAMES=("${(@f)$(cat "$COMPLETED")}")

# ── Load inventory ────────────────────────────────────────────────────────────
if [[ ! -f "$INVENTORY" ]]; then
  echo "ERROR: inventory file not found: $INVENTORY" >&2
  exit 1
fi

RESULTS="[]"

# Iterate over inventory workspaces that appear in the completed list
while IFS= read -r WS_JSON; do
  DIR=$(echo "$WS_JSON" | jq -r '.dir')
  NAME=$(echo "$WS_JSON" | jq -r '.name')
  # Use tfe_workspace_name if present, otherwise fall back to CE name
  TFE_WS_NAME=$(echo "$WS_JSON" | jq -r '.tfe_workspace_name // .name')

  # Skip if not in completed list
  if ! printf '%s\n' "${COMPLETED_NAMES[@]}" | grep -qx "$NAME"; then
    RESULT=$(jq -n \
      --arg ws   "$NAME" \
      --arg dir  "$DIR" \
      '{workspace: $ws, dir: $dir, status: "SKIPPED",
        tfe_workspace_id: null, ce_state_serial: null,
        tfe_state_serial: null, serials_match: false,
        plan_exit_code: null, plan_output_snippet: null,
        drift_detected: false, errors: ["Workspace not in completed list"]}')
    RESULTS=$(echo "$RESULTS" | jq ". + [$RESULT]")
    continue
  fi

  ERRORS="[]"
  STATUS="MIGRATED"
  DRIFT=false
  PLAN_EXIT=0
  PLAN_SNIPPET=""

  # 1. Get TFE workspace ID (use TFE workspace name for lookup)
  WS_ID=$(get_tfe_workspace_id "$TFE_WS_NAME" || echo "null")
  if [[ "$WS_ID" == "null" ]]; then
    ERRORS=$(echo "$ERRORS" | jq ". + [\"TFE workspace '$TFE_WS_NAME' not found\"]")
    STATUS="PLAN_FAILED"
  fi

  # 2. Get state serials
  CE_SERIAL=$(get_ce_state_serial "$DIR")
  TFE_SERIAL="null"
  SERIALS_MATCH=false

  if [[ "$WS_ID" != "null" ]]; then
    TFE_SERIAL=$(get_tfe_state_serial "$WS_ID" || echo "null")
    if [[ "$CE_SERIAL" != "null" && "$TFE_SERIAL" != "null" ]]; then
      if [[ "$CE_SERIAL" == "$TFE_SERIAL" ]]; then
        SERIALS_MATCH=true
      else
        STATUS="SERIAL_MISMATCH"
        ERRORS=$(echo "$ERRORS" | jq ". + [\"State serial mismatch: CE=$CE_SERIAL TFE=$TFE_SERIAL\"]")
      fi
    else
      ERRORS=$(echo "$ERRORS" | jq ". + [\"Could not compare serials: CE=${CE_SERIAL} TFE=${TFE_SERIAL}\"]")
    fi
  fi

  # 3. Run terraform plan (only if serials match and workspace is accessible)
  if [[ "$STATUS" == "MIGRATED" && -d "$DIR" ]]; then
    RAW_PLAN="$(run_plan_check "$DIR")"
    PLAN_EXIT="${RAW_PLAN%%|*}"
    PLAN_FULL="${RAW_PLAN#*|}"
    # Truncate plan output for JSON embedding (first 500 chars)
    PLAN_SNIPPET="${PLAN_FULL[1,500]}"

    case "$PLAN_EXIT" in
      0) ;; # No changes — good
      2) DRIFT=true; STATUS="DRIFT";
         ERRORS=$(echo "$ERRORS" | jq ". + [\"terraform plan detected changes (exit 2) — drift present\"]") ;;
      *) STATUS="PLAN_FAILED";
         ERRORS=$(echo "$ERRORS" | jq ". + [\"terraform plan failed (exit $PLAN_EXIT)\"]") ;;
    esac
  fi

  RESULT=$(jq -n \
    --arg  ws            "$NAME" \
    --arg  dir           "$DIR" \
    --arg  ws_id         "${WS_ID:-null}" \
    --argjson ce_serial  "${CE_SERIAL:-null}" \
    --argjson tfe_serial "${TFE_SERIAL:-null}" \
    --argjson s_match    "$(echo "$SERIALS_MATCH" | tr '[:upper:]' '[:lower:]')" \
    --argjson plan_exit  "${PLAN_EXIT:-null}" \
    --arg  plan_snippet  "$PLAN_SNIPPET" \
    --argjson drift      "$(echo "$DRIFT" | tr '[:upper:]' '[:lower:]')" \
    --arg  status        "$STATUS" \
    --argjson errors     "$ERRORS" \
    '{
      workspace:           $ws,
      dir:                 $dir,
      tfe_workspace_id:    $ws_id,
      ce_state_serial:     $ce_serial,
      tfe_state_serial:    $tfe_serial,
      serials_match:       $s_match,
      plan_exit_code:      $plan_exit,
      plan_output_snippet: $plan_snippet,
      drift_detected:      $drift,
      status:              $status,
      errors:              $errors
    }'
  )

  RESULTS=$(echo "$RESULTS" | jq ". + [$RESULT]")

done < <(jq -c '.[]' "$INVENTORY")

echo "$RESULTS" | jq '.' > "$OUTPUT"

# Print summary to stderr
TOTAL=$(echo "$RESULTS"   | jq 'length')
MIGRATED=$(echo "$RESULTS" | jq '[.[] | select(.status=="MIGRATED")] | length')
DRIFT_CT=$(echo "$RESULTS" | jq '[.[] | select(.status=="DRIFT")] | length')
FAILED=$(echo "$RESULTS"   | jq '[.[] | select(.status=="PLAN_FAILED" or .status=="SERIAL_MISMATCH")] | length')
SKIPPED=$(echo "$RESULTS"  | jq '[.[] | select(.status=="SKIPPED")] | length')

echo "─────────────────────────────────────────────" >&2
echo "Post-migration validation complete" >&2
echo "  Total:    $TOTAL" >&2
echo "  ✅ MIGRATED:        $MIGRATED" >&2
echo "  ⚠️  DRIFT:           $DRIFT_CT" >&2
echo "  ❌ FAILED/MISMATCH: $FAILED" >&2
echo "  ⏭  SKIPPED:         $SKIPPED" >&2
echo "─────────────────────────────────────────────" >&2
echo "Validation report written to $OUTPUT" >&2
