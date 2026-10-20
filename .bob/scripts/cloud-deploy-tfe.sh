#!/usr/bin/env bash
# cloud-deploy-tfe.sh — Enterprise CI/CD Cloud-Deploy Driver for Terraform Enterprise
#
# Provides simple platform actions using the official Terraform REST API:
#   1. provision : Creates TFE workspace in remote mode
#   2. plan      : Triggers speculative plan and checks drift/errors
#   3. apply     : Triggers live remote apply
#
# Usage:
#   .bob/scripts/cloud-deploy-tfe.sh --action <provision|plan|apply> --org <org> --workspace <ws>

set -euo pipefail

ACTION=""
DIR=""
ORG=""
WS=""
HOSTNAME_TFE="app.terraform.io"
TF_VERSION="1.14.3"

VAR_FILES=()

usage() {
  cat >&2 <<EOF
Usage: cloud-deploy-tfe.sh --action <provision|plan|apply> --org <tfe-org> --workspace <tfe-ws> [options]

Actions:
  provision          Create workspace in TFE & upload configured variables
  plan               Upload config & trigger speculative plan in TFE
  apply              Upload config, trigger remote plan & apply in TFE

Required:
  --action <action>  Action: provision | plan | apply
  --org <name>       TFE organization name
  --workspace <name> TFE workspace name

Options:
  --dir <path>       Terraform source directory (default: ibmcloud-infra2.0 or current dir)
  --var-file <file>  .tfvars file to parse & upload during provisioning (repeatable)
  --hostname <host>  TFE hostname (default: app.terraform.io)
  --tf-version <ver> Terraform version (default: 1.14.3)
  -h, --help         Show help
EOF
}

die() { echo "ERROR: $1" >&2; exit "${2:-1}"; }
log() { echo "[cloud-deploy $(date -u +%H:%M:%S)] $*" >&2; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --action)     ACTION="${2:?}"; shift 2 ;;
    --dir)        DIR="${2:?}"; shift 2 ;;
    --org)        ORG="${2:?}"; shift 2 ;;
    --workspace)  WS="${2:?}"; shift 2 ;;
    --var-file)   VAR_FILES+=("${2:?}"); shift 2 ;;
    --hostname)   HOSTNAME_TFE="${2:?}"; shift 2 ;;
    --tf-version) TF_VERSION="${2:?}"; shift 2 ;;
    -h|--help)    usage; exit 0 ;;
    *)            usage; die "Unknown parameter: $1" 2 ;;
  esac
done

DIR="${DIR:-ibmcloud-infra2.0}"

[[ -n "$ACTION" && -n "$ORG" && -n "$WS" ]] || { usage; die "--action, --org, and --workspace are required" 2; }
[[ -n "${TFE_TOKEN:-}" ]] || die "TFE_TOKEN environment variable is not set." 2

TFE_API="https://$HOSTNAME_TFE/api/v2"

# Helper: Get workspace ID
get_ws_id() {
  curl -s --header "Authorization: Bearer $TFE_TOKEN" \
    "$TFE_API/organizations/$ORG/workspaces/$WS" | jq -r '.data.id // empty'
}

# Helper: Upload / synchronize variables to TFE with automated category detection
sync_variables() {
  local ws_id="$1"
  local env_secret_re='(password|secret|token|api_key|private_key|credential|cert|client_secret|access_key)|(^|_)pat($|_)|^IC_|^IBMCLOUD_|^AWS_|^TF_VAR_'

  # 1. Upload variables from specified .tfvars files
  for vf in "${VAR_FILES[@]+"${VAR_FILES[@]}"}"; do
    local f="$vf"
    [[ "$f" = /* ]] || f="$DIR/$f"
    [[ -f "$f" ]] || { log "Notice: var-file $f not found, skipping"; continue; }
    log "Parsing and uploading variables from $f..."
    while IFS= read -r line || [[ -n "$line" ]]; do
      [[ "$line" =~ ^[[:space:]]*([A-Za-z0-9_]+)[[:space:]]*=[[:space:]]*(.*)$ ]] || continue
      local key="${BASH_REMATCH[1]}"
      local val="${BASH_REMATCH[2]}"
      local hcl=false
      local category="terraform"
      local sensitive=false

      if [[ "$val" == \"* ]]; then
        val="${val#\"}"; val="${val%%\"*}"
      else
        val="${val%%#*}"; val="$(echo "$val" | sed -e 's/[[:space:]]*$//')"
        if [[ "$val" =~ ^(true|false|[0-9.]+)$ ]]; then
          hcl=true
        elif [[ "$val" == \[* || "$val" == \{* ]]; then
          hcl=true
        fi
      fi

      # Detect category and sensitivity
      if [[ "$key" =~ ^(TF_VAR_|IC_|IBMCLOUD_|AWS_) ]]; then
        category="env"
      fi
      if [[ "$key" =~ $env_secret_re ]]; then
        sensitive=true
      fi

      curl -s --request POST \
        --header "Authorization: Bearer $TFE_TOKEN" \
        --header "Content-Type: application/vnd.api+json" \
        --data "{
          \"data\": {
            \"type\": \"vars\",
            \"attributes\": {
              \"key\": \"$key\",
              \"value\": \"$val\",
              \"category\": \"$category\",
              \"hcl\": $hcl,
              \"sensitive\": $sensitive
            }
          }
        }" \
        "$TFE_API/workspaces/$ws_id/vars" >/dev/null || true
      log "  - Uploaded $category var: $key (sensitive: $sensitive)"
    done < "$f"
  done

  # 2. Check and upload SSH Public Key if found locally and declared in variables.tf
  if grep -q 'variable "ssh_public_key"' "$DIR"/*.tf 2>/dev/null; then
    local ssh_key=""
    for k in ~/.ssh/id_rsa.pub ~/.ssh/id_ed25519.pub ~/.ssh/*.pub; do
      if [[ -f "$k" ]]; then ssh_key="$(cat "$k")"; break; fi
    done
    if [[ -n "$ssh_key" ]]; then
      curl -s --request POST \
        --header "Authorization: Bearer $TFE_TOKEN" \
        --header "Content-Type: application/vnd.api+json" \
        --data "{
          \"data\": {
            \"type\": \"vars\",
            \"attributes\": {
              \"key\": \"ssh_public_key\",
              \"value\": \"$ssh_key\",
              \"category\": \"terraform\",
              \"hcl\": false,
              \"sensitive\": false
            }
          }
        }" \
        "$TFE_API/workspaces/$ws_id/vars" >/dev/null || true
      log "  - Uploaded terraform var: ssh_public_key"
    fi
  fi
}

action_provision() {
  log "Checking if workspace '$WS' exists in org '$ORG'..."
  local ws_id
  ws_id="$(get_ws_id)"
  if [[ -n "$ws_id" ]]; then
    log "Workspace already exists: $ws_id"
  else
    log "Creating workspace '$WS' (mode: remote, terraform: $TF_VERSION)..."
    local resp
    resp=$(curl -s --request POST \
      --header "Authorization: Bearer $TFE_TOKEN" \
      --header "Content-Type: application/vnd.api+json" \
      --data "{
        \"data\": {
          \"type\": \"workspaces\",
          \"attributes\": {
            \"name\": \"$WS\",
            \"execution-mode\": \"remote\",
            \"terraform-version\": \"$TF_VERSION\",
            \"auto-apply\": false
          }
        }
      }" \
      "$TFE_API/organizations/$ORG/workspaces")

    ws_id=$(echo "$resp" | jq -r '.data.id // empty')
    [[ -n "$ws_id" ]] || { echo "$resp" >&2; die "Failed to create workspace"; }
    log "Workspace created successfully: $ws_id"
  fi

  # Auto-sync variables if provided
  if [[ ${#VAR_FILES[@]} -gt 0 || -d "$DIR" ]]; then
    sync_variables "$ws_id"
  fi
}

# Helper: Package and upload Terraform configuration to TFE
upload_configuration() {
  local ws_id="$1"
  [[ -d "$DIR" ]] || die "Terraform code directory not found: $DIR" 2

  log "Packaging and uploading configuration from '$DIR' to TFE..."
  local cv_resp cv_id upload_url tar_file
  cv_resp=$(curl -s --request POST \
    --header "Authorization: Bearer $TFE_TOKEN" \
    --header "Content-Type: application/vnd.api+json" \
    --data '{"data":{"type":"configuration-versions","attributes":{"auto-queue-runs":false,"speculative":false}}}' \
    "$TFE_API/workspaces/$ws_id/configuration-versions")

  cv_id=$(echo "$cv_resp" | jq -r '.data.id // empty')
  upload_url=$(echo "$cv_resp" | jq -r '.data.attributes["upload-url"] // empty')
  [[ -n "$cv_id" && -n "$upload_url" ]] || { echo "$cv_resp" >&2; die "Failed to create configuration version"; }

  tar_file="/tmp/tfe-config-$WS-$$.tar.gz"
  # Package terraform code (excluding .git, .terraform cache, local state, and backend.tf so remote runners don't prompt for migration)
  tar -czf "$tar_file" -C "$DIR" \
    --exclude='.terraform' \
    --exclude='.git' \
    --exclude='*.tfstate*' \
    --exclude='backend.tf' \
    .
  curl -s -T "$tar_file" "$upload_url"
  rm -f "$tar_file"
  log "Configuration uploaded (CV: $cv_id)."
  echo "$cv_id"
}

action_plan() {
  local ws_id cv_id
  ws_id="$(get_ws_id)"
  [[ -n "$ws_id" ]] || die "Workspace '$WS' not found in org '$ORG'."

  cv_id="$(upload_configuration "$ws_id")"

  log "Triggering speculative plan for workspace $WS ($ws_id)..."
  local run_resp run_id
  run_resp=$(curl -s --request POST \
    --header "Authorization: Bearer $TFE_TOKEN" \
    --header "Content-Type: application/vnd.api+json" \
    --data "{
      \"data\": {
        \"attributes\": {
          \"is-destroy\": false,
          \"message\": \"cloud-deploy speculative plan verification\",
          \"plan-only\": true
        },
        \"type\": \"runs\",
        \"relationships\": {
          \"workspace\": {
            \"data\": { \"type\": \"workspaces\", \"id\": \"$ws_id\" }
          },
          \"configuration-version\": {
            \"data\": { \"type\": \"configuration-versions\", \"id\": \"$cv_id\" }
          }
        }
      }
    }" \
    "$TFE_API/runs")

  run_id=$(echo "$run_resp" | jq -r '.data.id // empty')
  [[ -n "$run_id" ]] || { echo "$run_resp" >&2; die "Failed to trigger plan run"; }

  log "Plan triggered: $run_id. Polling status..."
  local status="" poll_count=0
  while [[ $poll_count -lt 30 ]]; do
    sleep 4
    local run_data
    run_data=$(curl -s --header "Authorization: Bearer $TFE_TOKEN" "$TFE_API/runs/$run_id")
    status=$(echo "$run_data" | jq -r '.data.attributes.status')
    log "  Run status: $status"
    case "$status" in
      planned_and_finished|planned) log "Plan completed successfully ($status)."; return 0 ;;
      errored|canceled|discarded)
        local plan_id log_url
        plan_id=$(echo "$run_data" | jq -r '.data.relationships.plan.data.id // empty')
        if [[ -n "$plan_id" ]]; then
          log_url=$(curl -s --header "Authorization: Bearer $TFE_TOKEN" "$TFE_API/plans/$plan_id" | jq -r '.data.attributes["log-read-url"] // empty')
          echo >&2; echo "══════════════ TFE PLAN ERROR LOG ══════════════" >&2
          [[ -n "$log_url" ]] && curl -s "$log_url" >&2
          echo >&2; echo "════════════════════════════════════════════════" >&2
        fi
        die "Plan ended with failure status: $status"
        ;;
    esac
    ((poll_count++))
  done
  die "Plan run timed out."
}

action_apply() {
  local ws_id cv_id
  ws_id="$(get_ws_id)"
  [[ -n "$ws_id" ]] || die "Workspace '$WS' not found in org '$ORG'."

  cv_id="$(upload_configuration "$ws_id")"

  log "Triggering deployment run for workspace $WS ($ws_id)..."
  local run_resp run_id
  run_resp=$(curl -s --request POST \
    --header "Authorization: Bearer $TFE_TOKEN" \
    --header "Content-Type: application/vnd.api+json" \
    --data "{
      \"data\": {
        \"attributes\": {
          \"is-destroy\": false,
          \"message\": \"cloud-deploy release execution\",
          \"plan-only\": false
        },
        \"type\": \"runs\",
        \"relationships\": {
          \"workspace\": {
            \"data\": { \"type\": \"workspaces\", \"id\": \"$ws_id\" }
          },
          \"configuration-version\": {
            \"data\": { \"type\": \"configuration-versions\", \"id\": \"$cv_id\" }
          }
        }
      }
    }" \
    "$TFE_API/runs")

  run_id=$(echo "$run_resp" | jq -r '.data.id // empty')
  [[ -n "$run_id" ]] || { echo "$run_resp" >&2; die "Failed to trigger run"; }

  log "Run triggered: $run_id. Waiting for plan..."
  local status="" poll_count=0
  while [[ $poll_count -lt 30 ]]; do
    sleep 4
    status=$(curl -s --header "Authorization: Bearer $TFE_TOKEN" "$TFE_API/runs/$run_id" | jq -r '.data.attributes.status')
    log "  Run status: $status"
    if [[ "$status" == "planned" ]]; then
      break
    elif [[ "$status" =~ ^(errored|canceled|discarded)$ ]]; then
      die "Run failed before apply: $status"
    fi
    ((poll_count++))
  done

  read -r -p "Plan finished. Proceed to apply run $run_id? [y/N] " ans
  [[ "$ans" =~ ^[yY](es)?$ ]] || die "Apply aborted by user." 4

  curl -s --request POST \
    --header "Authorization: Bearer $TFE_TOKEN" \
    --header "Content-Type: application/vnd.api+json" \
    --data '{"comment": "Approved via cloud-deploy-tfe.sh"}' \
    "$TFE_API/runs/$run_id/actions/apply" > /dev/null

  log "Apply submitted. Monitoring final status..."
  while true; do
    sleep 4
    status=$(curl -s --header "Authorization: Bearer $TFE_TOKEN" "$TFE_API/runs/$run_id" | jq -r '.data.attributes.status')
    log "  Run status: $status"
    case "$status" in
      applied) log "Apply completed successfully!"; return 0 ;;
      errored|canceled) die "Apply failed: $status" ;;
    esac
  done
}

case "$ACTION" in
  provision) action_provision ;;
  plan)      action_plan ;;
  apply)     action_apply ;;
esac
