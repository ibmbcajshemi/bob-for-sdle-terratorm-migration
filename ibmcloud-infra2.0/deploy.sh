#!/usr/bin/env bash
# =============================================================================
#  ibmcloud-infra-v2 — Cloud Deploy Automation
# -----------------------------------------------------------------------------
#  Provisions COS + VPC/VSI + Code Engine on IBM Cloud via Terraform, with
#  remote state in IBM COS (S3-compatible backend).
#
#  Usage:
#    ./deploy.sh <command> -e <dev|prod> [options]
#
#  Commands:
#    plan        Preflight, init, validate and create a saved plan
#    apply       Everything in 'plan', then back up state, confirm and apply
#    outputs     Show deployment outputs for an environment
#
#  Options:
#    -e, --env <env>     Target environment: dev | prod        (required)
#    --bootstrap         Create/verify the COS state bucket first (bootstrap/)
#    --auto-approve      Skip the confirmation prompt (dev only, never for
#                        plans that delete or replace resources)
#    --skip-smoke        Skip post-deploy smoke tests
#    -h, --help          Show this help
#
#  Required environment (export or put in .env — never committed):
#    TF_VAR_ibmcloud_api_key   IBM Cloud API key
#    AWS_ACCESS_KEY_ID         COS HMAC access key  (NOT an AWS IAM key)
#    AWS_SECRET_ACCESS_KEY     COS HMAC secret key  (NOT an AWS IAM key)
#    TF_BACKEND_bucket         State bucket name (bootstrap output)
#    TF_VAR_ssh_public_key     SSH public key for the VSI
#
#  Optional:
#    TF_STATE_KEY              Override the state object key
#                              (default: ibmcloud-infra-v2/<env>/terraform.tfstate)
#    NO_COLOR=1                Disable colours
#
#  Safety: this script never runs 'terraform destroy' or 'terraform state rm',
#  and it never prints credentials. State is pulled and verified before apply.
# =============================================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# ---------------------------------------------------------------------------
#  Styling
# ---------------------------------------------------------------------------
IS_TTY=false; [[ -t 1 ]] && IS_TTY=true
if [[ "$IS_TTY" == true && -z "${NO_COLOR:-}" ]]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
  C_BLUE=$'\033[38;5;33m'; C_PURPLE=$'\033[38;5;99m'; C_CYAN=$'\033[38;5;44m'
  C_GREEN=$'\033[38;5;42m'; C_YELLOW=$'\033[38;5;214m'; C_RED=$'\033[38;5;196m'
else
  C_RESET=""; C_BOLD=""; C_DIM=""; C_BLUE=""; C_PURPLE=""; C_CYAN=""
  C_GREEN=""; C_YELLOW=""; C_RED=""
fi

RULE="────────────────────────────────────────────────────────────────────"
STEP_NUM=0
STEP_TOTAL=0
START_TS=$(date +%s)

banner() {
  printf '%s' "$C_BLUE$C_BOLD"
  cat <<'EOF'

   ╦╔╗ ╔╦╗  ╔═╗┬  ┌─┐┬ ┬┌┬┐   ╔╦╗┌─┐┌─┐┬  ┌─┐┬ ┬
   ║╠╩╗║║║  ║  │  │ ││ │ ││    ║║├┤ ├─┘│  │ │└┬┘
   ╩╚═╝╩ ╩  ╚═╝┴─┘└─┘└─┘─┴┘   ═╩╝└─┘┴  ┴─┘└─┘ ┴
EOF
  printf '%s' "$C_RESET"
  printf '   %sibmcloud-infra-v2%s  %s·%s  COS  ·  VPC / VSI  ·  Code Engine\n' \
    "$C_PURPLE$C_BOLD" "$C_RESET" "$C_DIM" "$C_RESET"
  printf '   %s%s%s\n\n' "$C_DIM" "$RULE" "$C_RESET"
}

step() {
  STEP_NUM=$((STEP_NUM + 1))
  printf '\n%s[%d/%d]%s %s%s%s\n' "$C_PURPLE$C_BOLD" "$STEP_NUM" "$STEP_TOTAL" \
    "$C_RESET" "$C_BOLD" "$1" "$C_RESET"
  printf '%s%s%s\n' "$C_DIM" "$RULE" "$C_RESET"
}

info() { printf '  %s›%s %s\n' "$C_CYAN" "$C_RESET" "$*"; }
ok()   { printf '  %s✔%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '  %s▲%s %s\n' "$C_YELLOW" "$C_RESET" "$*"; }
fail() { printf '\n  %s✖ %s%s\n\n' "$C_RED$C_BOLD" "$*" "$C_RESET" >&2; exit 1; }
kv()   { printf '    %s%-22s%s %s\n' "$C_DIM" "$1" "$C_RESET" "$2"; }

spinner() {
  # spinner <pid> <message>
  local pid=$1 msg=$2 frames='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏' i=0
  # Draws on fd 3 (the original terminal) so frames stay out of the log file.
  if [[ "$IS_TTY" != true ]]; then wait "$pid"; return $?; fi
  while kill -0 "$pid" 2>/dev/null; do
    printf '\r  %s%s%s %s' "$C_CYAN" "${frames:i++%${#frames}:1}" "$C_RESET" "$msg" >&3
    sleep 0.1
  done
  printf '\r\033[K' >&3
  wait "$pid"
}

run_quiet() {
  # run_quiet <message> <cmd...> — spinner while running; output shown only on failure
  local msg=$1 tmp; shift
  tmp=$(mktemp)
  "$@" >"$tmp" 2>&1 &
  if spinner $! "$msg"; then rm -f "$tmp"; return 0; fi
  warn "$msg failed:"; sed 's/^/      /' "$tmp"; rm -f "$tmp"; return 1
}

elapsed() {
  local s=$(( $(date +%s) - START_TS ))
  printf '%dm %02ds' $((s / 60)) $((s % 60))
}

on_error() {
  local code=$?
  printf '\n  %s✖ Deployment aborted (exit %d) at step %d/%d after %s%s\n' \
    "$C_RED$C_BOLD" "$code" "$STEP_NUM" "$STEP_TOTAL" "$(elapsed)" "$C_RESET" >&2
  [[ -n "${LOG_FILE:-}" ]] && printf '    %sFull log:%s %s\n\n' "$C_DIM" "$C_RESET" "$LOG_FILE" >&2
  exit "$code"
}
trap on_error ERR
trap 'printf "\n"; fail "Interrupted by user"' INT

usage() { sed -n '2,38p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

# ---------------------------------------------------------------------------
#  Arguments
# ---------------------------------------------------------------------------
COMMAND="${1:-}"
[[ -z "$COMMAND" || "$COMMAND" == "-h" || "$COMMAND" == "--help" ]] && usage
shift

ENV=""; DO_BOOTSTRAP=false; AUTO_APPROVE=false; SKIP_SMOKE=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    -e|--env)       ENV="${2:-}"; shift 2 ;;
    --bootstrap)    DO_BOOTSTRAP=true; shift ;;
    --auto-approve) AUTO_APPROVE=true; shift ;;
    --skip-smoke)   SKIP_SMOKE=true; shift ;;
    -h|--help)      usage ;;
    *)              fail "Unknown option: $1 (see --help)" ;;
  esac
done

case "$COMMAND" in plan|apply|outputs) ;; *) fail "Unknown command: $COMMAND (plan | apply | outputs)" ;; esac
case "$ENV" in dev|prod) ;; *) fail "Environment required: -e dev | -e prod" ;; esac
[[ "$ENV" == "prod" && "$AUTO_APPROVE" == true ]] && fail "--auto-approve is not permitted for prod"

# Load .env if present (values are never echoed)
# (.env.example references possibly-unset vars such as ${SSH_PUBLIC_KEY})
if [[ -f .env ]]; then
  set -a +u
  # shellcheck disable=SC1091
  source .env
  set +a -u
fi

TF_STATE_KEY="${TF_STATE_KEY:-ibmcloud-infra-v2/${ENV}/terraform.tfstate}"
VAR_FILE="environments/${ENV}.tfvars"
RUN_ID="$(date +%Y%m%d-%H%M%S)"
ART_DIR="$SCRIPT_DIR/.deploy"
PLAN_FILE="$ART_DIR/plans/${ENV}-${RUN_ID}.tfplan"
BACKUP_FILE="$ART_DIR/backups/${ENV}-${RUN_ID}.tfstate"
LOG_FILE="$ART_DIR/logs/${ENV}-${COMMAND}-${RUN_ID}.log"
mkdir -p "$ART_DIR/plans" "$ART_DIR/backups" "$ART_DIR/logs"
chmod 700 "$ART_DIR" "$ART_DIR/backups"   # state backups may contain sensitive values

# Keep the real terminal on fd 3 for the spinner, then mirror all other
# output to the log file (colours stripped there).
exec 3>&1
exec > >(tee >(sed $'s/\033\\[[0-9;]*[A-Za-z]//g' >> "$LOG_FILE")) 2>&1

export TF_IN_AUTOMATION=1 TF_INPUT=0

# ---------------------------------------------------------------------------
#  Helpers
# ---------------------------------------------------------------------------
require_var() {
  # Checks presence only — never prints the value.
  local name=$1 val="${!1:-}"
  if [[ -z "$val" || "$val" == REPLACE_WITH_* ]]; then
    warn "$name is not set"; return 1
  fi
  ok "$name ${C_DIM}(set, redacted)${C_RESET}"
}

plan_counts() {
  # plan_counts <dir> <planfile>  ->  "add change destroy"
  terraform -chdir="$1" show -json "$2" | jq -r '
    [.resource_changes[]?.change.actions] as $a
    | "\($a | map(select(index("create"))) | length) \($a | map(select(. == ["update"])) | length) \($a | map(select(index("delete"))) | length)"'
}

list_destructive() {
  terraform -chdir="$1" show -json "$2" | jq -r '
    .resource_changes[]? | select(.change.actions | index("delete"))
    | "\(.change.actions | join("/"))  \(.address)"'
}

confirm() {
  # confirm <prompt> <expected-answer>
  local answer
  printf '\n  %s?%s %s ' "$C_YELLOW$C_BOLD" "$C_RESET" "$1"
  read -r answer </dev/tty || answer=""
  [[ "$answer" == "$2" ]]
}

guarded_plan() {
  # guarded_plan <dir> <planfile> [terraform plan args...]
  # Creates a plan and prints a styled summary. Returns 0 always; sets
  # PLAN_ADD / PLAN_CHANGE / PLAN_DESTROY.
  local dir=$1 out=$2; shift 2
  local rc=0
  terraform -chdir="$dir" plan -input=false -out="$out" -detailed-exitcode "$@" || rc=$?
  [[ $rc -eq 1 ]] && fail "terraform plan failed in $dir"
  read -r PLAN_ADD PLAN_CHANGE PLAN_DESTROY <<<"$(plan_counts "$dir" "$out")"
  printf '\n    %s+ %s to add%s   %s~ %s to change%s   %s- %s to destroy%s\n' \
    "$C_GREEN" "$PLAN_ADD" "$C_RESET" "$C_YELLOW" "$PLAN_CHANGE" "$C_RESET" \
    "$C_RED" "$PLAN_DESTROY" "$C_RESET"
  if [[ "$PLAN_DESTROY" -gt 0 ]]; then
    warn "${C_RED}${C_BOLD}Plan deletes or replaces resources:${C_RESET}"
    list_destructive "$dir" "$out" | sed 's/^/      /'
  fi
}

# ---------------------------------------------------------------------------
#  Stages
# ---------------------------------------------------------------------------
stage_preflight() {
  step "Preflight checks"
  local missing=0 tool
  for tool in terraform jq curl; do
    if command -v "$tool" >/dev/null 2>&1; then ok "$tool found"
    else warn "$tool not found"; missing=1; fi
  done
  [[ $missing -eq 0 ]] || fail "Install the missing tools and retry"

  local tfv
  tfv=$(terraform version -json | jq -r .terraform_version)
  if [[ "$(printf '%s\n1.5.0\n' "$tfv" | sort -V | head -1)" != "1.5.0" ]]; then
    fail "Terraform $tfv is below the required 1.5.0"
  fi
  ok "Terraform $tfv (>= 1.5.0)"

  [[ -f "$VAR_FILE" ]] || fail "Missing var-file: $VAR_FILE"
  ok "Var-file $VAR_FILE"

  missing=0
  require_var TF_VAR_ibmcloud_api_key || missing=1
  require_var AWS_ACCESS_KEY_ID       || missing=1
  require_var AWS_SECRET_ACCESS_KEY   || missing=1
  if [[ "$COMMAND" != "outputs" ]]; then
    require_var TF_VAR_ssh_public_key || missing=1
  fi
  if [[ "$DO_BOOTSTRAP" == false ]]; then
    require_var TF_BACKEND_bucket || missing=1
  fi
  [[ $missing -eq 0 ]] || fail "Required environment variables are missing (see --help or .env.example)"
}

stage_bootstrap() {
  step "Bootstrap state bucket (bootstrap/, local backend)"
  local bdir="bootstrap" bplan="$ART_DIR/plans/bootstrap-${ENV}-${RUN_ID}.tfplan"

  if [[ -f "$bdir/terraform.tfstate" ]]; then
    cp "$bdir/terraform.tfstate" "$ART_DIR/backups/bootstrap-${ENV}-${RUN_ID}.tfstate"
    ok "Bootstrap local state copied to .deploy/backups/"
  fi

  run_quiet "Initialising bootstrap" terraform -chdir="$bdir" init -input=false
  ok "Bootstrap initialised"

  guarded_plan "$bdir" "$bplan" -var="environment=${ENV}"

  if [[ "$PLAN_DESTROY" -gt 0 ]]; then
    fail "Bootstrap plan would delete the state bucket/instance. Bootstrap uses a single local state; refusing to continue."
  fi
  if [[ "$PLAN_ADD" -eq 0 && "$PLAN_CHANGE" -eq 0 ]]; then
    ok "State bucket already in place — nothing to do"
  else
    terraform -chdir="$bdir" apply -input=false "$bplan"
    ok "Bootstrap applied"
  fi

  TF_BACKEND_bucket=$(terraform -chdir="$bdir" output -raw state_bucket_name)
  export TF_BACKEND_bucket
  ok "State bucket: ${C_BOLD}${TF_BACKEND_bucket}${C_RESET}"
}

stage_init() {
  step "Initialise remote backend (IBM COS)"
  kv "bucket" "$TF_BACKEND_bucket"
  kv "key" "$TF_STATE_KEY"

  # Warn if the working dir currently points at a different state key —
  # e.g. state created earlier under the default key in versions.tf.
  local current_key
  current_key=$(jq -r '.backend.config.key // empty' .terraform/terraform.tfstate 2>/dev/null || true)
  if [[ -n "$current_key" && "$current_key" != "$TF_STATE_KEY" ]]; then
    warn "Working dir was last initialised with key ${C_BOLD}${current_key}${C_RESET}"
    warn "If ${ENV} state lives there, re-run with TF_STATE_KEY=${current_key}"
  fi

  # Credentials come from AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY in the
  # environment — never passed on the command line.
  # -reconfigure only re-points the backend; it never copies or migrates state.
  run_quiet "Running terraform init" terraform init -input=false -reconfigure \
    -backend-config="bucket=${TF_BACKEND_bucket}" \
    -backend-config="key=${TF_STATE_KEY}"
  ok "Backend initialised"

  run_quiet "Validating configuration" terraform validate -no-color
  ok "Configuration valid"

  terraform fmt -check -recursive >/dev/null 2>&1 \
    && ok "Formatting clean" || warn "terraform fmt reports unformatted files (non-blocking)"
}

stage_backup() {
  step "Back up and verify remote state"
  terraform state pull > "$BACKUP_FILE"

  if [[ ! -s "$BACKUP_FILE" ]]; then
    rm -f "$BACKUP_FILE"
    STATE_RESOURCES=0
    warn "No existing state at ${C_BOLD}${TF_STATE_KEY}${C_RESET}"
    return
  fi

  jq -e '.serial and .lineage' "$BACKUP_FILE" >/dev/null \
    || fail "State backup is not valid Terraform state JSON — aborting"
  STATE_RESOURCES=$(jq '[.resources[]?] | length' "$BACKUP_FILE")
  ok "Backup verified ${C_DIM}(serial $(jq -r .serial "$BACKUP_FILE"), ${STATE_RESOURCES} resources)${C_RESET}"
  kv "saved to" "${BACKUP_FILE#$SCRIPT_DIR/}"
}

stage_plan() {
  step "Plan changes for ${ENV}"
  guarded_plan "." "$PLAN_FILE" -var-file="$VAR_FILE"
  kv "plan file" "${PLAN_FILE#$SCRIPT_DIR/}"
}

stage_apply() {
  step "Apply"
  if [[ "$PLAN_ADD" -eq 0 && "$PLAN_CHANGE" -eq 0 && "$PLAN_DESTROY" -eq 0 ]]; then
    ok "Infrastructure is up to date — nothing to apply"
    return
  fi

  if [[ "${STATE_RESOURCES:-0}" -eq 0 ]]; then
    warn "This is a ${C_BOLD}fresh deployment${C_RESET} — the state key holds no resources."
    warn "If ${ENV} was deployed before under a different key, stop and set TF_STATE_KEY."
    confirm "Type 'fresh' to deploy into an empty state:" "fresh" || fail "Cancelled"
  fi

  if [[ "$PLAN_DESTROY" -gt 0 ]]; then
    confirm "Plan destroys/replaces ${PLAN_DESTROY} resource(s). Type 'destroy-${ENV}' to proceed:" \
      "destroy-${ENV}" || fail "Cancelled — no changes applied"
  elif [[ "$ENV" == "prod" ]]; then
    confirm "Apply to ${C_RED}${C_BOLD}PROD${C_RESET}? Type 'prod' to proceed:" "prod" || fail "Cancelled"
  elif [[ "$AUTO_APPROVE" == false ]]; then
    confirm "Apply to ${ENV}? [y/N]" "y" || fail "Cancelled"
  else
    info "Auto-approve enabled (dev, non-destructive plan)"
  fi

  terraform apply -input=false "$PLAN_FILE"
  ok "Apply complete"
}

stage_outputs() {
  step "Deployment outputs"
  local json
  json=$(terraform output -json 2>/dev/null || echo '{}')
  if [[ "$(jq 'length' <<<"$json")" -eq 0 ]]; then
    warn "No outputs found for ${ENV}"; return
  fi
  while IFS=$'\t' read -r k v; do kv "$k" "$v"; done < <(
    jq -r 'to_entries[] | [.key, (if .value.sensitive then "(sensitive)" else (.value.value | tostring) end)] | @tsv' <<<"$json"
  )
  CE_URL=$(jq -r '.code_engine_app_url.value // empty' <<<"$json")
  VSI_IP=$(jq -r '.vsi_floating_ip.value // empty' <<<"$json")
}

stage_smoke() {
  step "Smoke tests"
  if [[ -n "${CE_URL:-}" ]]; then
    local code="000" i
    (
      for i in $(seq 1 12); do
        code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$CE_URL" || true)
        [[ "$code" =~ ^2|^3 ]] && exit 0
        sleep 5
      done
      exit 1
    ) &
    if spinner $! "Waiting for Code Engine app (scale-from-zero can take ~30s)"; then
      ok "Code Engine app responding at ${C_BOLD}${CE_URL}${C_RESET}"
    else
      warn "Code Engine app did not return 2xx/3xx within 60s: $CE_URL"
    fi
  else
    warn "No Code Engine URL output — skipped"
  fi

  if [[ -n "${VSI_IP:-}" ]] && command -v nc >/dev/null 2>&1; then
    if nc -z -w 5 "$VSI_IP" 22 >/dev/null 2>&1; then
      ok "VSI SSH port reachable at ${C_BOLD}${VSI_IP}:22${C_RESET}"
    else
      warn "VSI ${VSI_IP}:22 not reachable yet (instance may still be booting)"
    fi
  fi
}

summary() {
  printf '\n%s%s%s\n' "$C_GREEN" "$RULE" "$C_RESET"
  printf '  %s✔ %s complete for %s%s  %s(%s)%s\n' "$C_GREEN$C_BOLD" "$COMMAND" "$ENV" \
    "$C_RESET" "$C_DIM" "$(elapsed)" "$C_RESET"
  [[ -f "$BACKUP_FILE" ]] && kv "state backup" "${BACKUP_FILE#$SCRIPT_DIR/}"
  [[ -f "$PLAN_FILE" ]]   && kv "plan" "${PLAN_FILE#$SCRIPT_DIR/}"
  kv "log" "${LOG_FILE#$SCRIPT_DIR/}"
  if [[ "$COMMAND" == "plan" ]]; then
    info "Next: ${C_BOLD}./deploy.sh apply -e ${ENV}${C_RESET}"
  fi
  printf '%s%s%s\n\n' "$C_GREEN" "$RULE" "$C_RESET"
}

# ---------------------------------------------------------------------------
#  Main
# ---------------------------------------------------------------------------
banner
kv "command" "$COMMAND"
kv "environment" "$( [[ $ENV == prod ]] && printf '%sPROD%s' "$C_RED$C_BOLD" "$C_RESET" || echo dev )"
kv "run id" "$RUN_ID"

case "$COMMAND" in
  plan)    STEP_TOTAL=4 ;;
  apply)   STEP_TOTAL=6; [[ "$SKIP_SMOKE" == false ]] && STEP_TOTAL=7 ;;
  outputs) STEP_TOTAL=3 ;;
esac
[[ "$DO_BOOTSTRAP" == true && "$COMMAND" != "outputs" ]] && STEP_TOTAL=$((STEP_TOTAL + 1))

stage_preflight
[[ "$DO_BOOTSTRAP" == true && "$COMMAND" != "outputs" ]] && stage_bootstrap
stage_init

case "$COMMAND" in
  plan)
    stage_backup
    stage_plan
    ;;
  apply)
    stage_backup
    stage_plan
    stage_apply
    stage_outputs
    [[ "$SKIP_SMOKE" == false ]] && stage_smoke
    ;;
  outputs)
    stage_outputs
    ;;
esac

summary
