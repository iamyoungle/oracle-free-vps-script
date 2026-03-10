#!/usr/bin/env bash
# =============================================================================
# Oracle Free ARM VPS — macOS / Linux Auto-Provisioner
# =============================================================================
# Oracle Cloud's free-tier ARM instances (4 OCPUs, 24 GB RAM) are frequently
# "out of capacity". This script repeatedly requests one until it succeeds.
#
# Usage:
#   ./oracle_vps.sh            Start the provisioning loop
#   ./oracle_vps.sh --setup    List images / subnets / domains to fill config
#   ./oracle_vps.sh --help     Show this help
#
# Prerequisites (install once):
#   macOS:          brew install oci-cli jq
#   Debian/Ubuntu:  sudo apt install jq && pip install oci-cli
#   RHEL/Fedora:    sudo dnf install jq && pip install oci-cli
#   Then:           oci session authenticate   (repeat every 24 h)
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.sh"

# ── Colours (disabled when not a terminal) ───────────────────────────────────
if [[ -t 1 ]]; then
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
  CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; CYAN=''; BOLD=''; RESET=''
fi

# ── Helpers ──────────────────────────────────────────────────────────────────

log()         { echo -e "${RESET}$*"; }
log_info()    { echo -e "${CYAN}  $*${RESET}"; }
log_ok()      { echo -e "${GREEN}  $*${RESET}"; }
log_warn()    { echo -e "${YELLOW}  $*${RESET}"; }
log_error()   { echo -e "${RED}  $*${RESET}" >&2; }
log_section() { echo -e "\n${BOLD}$*${RESET}"; }

# ── Load config ──────────────────────────────────────────────────────────────

if [[ ! -f "$CONFIG_FILE" ]]; then
  log_error "config.sh not found at $CONFIG_FILE"
  exit 1
fi
# shellcheck source=config.sh
source "$CONFIG_FILE"

# ── Dependency check ─────────────────────────────────────────────────────────

# Prints OS-appropriate install hints for missing tools.
_install_hint() {
  local tools="$*"
  case "$(uname -s)" in
    Darwin)
      echo "  macOS:         brew install $tools"
      ;;
    Linux)
      if   command -v apt  &>/dev/null; then
        echo "  Debian/Ubuntu: sudo apt install $tools"
        echo "  (for oci-cli): pip install oci-cli"
      elif command -v dnf  &>/dev/null; then
        echo "  RHEL/Fedora:   sudo dnf install $tools"
        echo "  (for oci-cli): pip install oci-cli"
      elif command -v yum  &>/dev/null; then
        echo "  CentOS:        sudo yum install $tools"
        echo "  (for oci-cli): pip install oci-cli"
      else
        echo "  Install with your package manager: $tools"
        echo "  (for oci-cli): pip install oci-cli"
      fi
      ;;
    *)
      echo "  See: https://docs.oracle.com/en-us/iaas/Content/API/SDKDocs/cliinstall.htm"
      ;;
  esac
}

check_deps() {
  local missing=()
  for cmd in oci jq; do
    command -v "$cmd" &>/dev/null || missing+=("$cmd")
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    log_error "Missing required tools: ${missing[*]}"
    _install_hint "${missing[*]}" >&2
    exit 1
  fi
}

# ── Shared OCI auth flags (used in every oci call) ───────────────────────────

oci_auth_flags() {
  echo "--config-file $OCI_CONFIG_FILE --profile $OCI_PROFILE --auth security_token"
}

# ── Setup mode ───────────────────────────────────────────────────────────────
# Lists the images, subnets, and availability domains from your account so you
# can copy the right OCIDs into config.sh.

run_setup() {
  log_section "=== Setup Mode: Discovering Oracle Cloud Resources ==="

  log_section "### ARM Images (aarch64) ###"
  # shellcheck disable=SC2046
  oci compute image list --all -c "$TENANCY_ID" $(oci_auth_flags) 2>/dev/null \
    | jq -r '
        .data[]
        | select(."display-name" | test("aarch64"; "i"))
        | "  \(."display-name")\n  ID: \(.id)\n"
      ' \
    || log_warn "(Could not fetch images — check authentication)"

  log_section "### Subnets ###"
  # shellcheck disable=SC2046
  oci network subnet list -c "$TENANCY_ID" $(oci_auth_flags) 2>/dev/null \
    | jq -r '.data[] | "  \(."display-name")\n  ID: \(.id)\n"' \
    || log_warn "(Could not fetch subnets — check authentication)"

  log_section "### Availability Domains ###"
  # shellcheck disable=SC2046
  oci iam availability-domain list -c "$TENANCY_ID" $(oci_auth_flags) 2>/dev/null \
    | jq -r '.data[].name | "  \(.)"' \
    || log_warn "(Could not fetch availability domains — check authentication)"

  log ""
  log "Copy the IDs above into ${BOLD}config.sh${RESET}, then run: ./oracle_vps.sh"
}

# ── Config validation ─────────────────────────────────────────────────────────
# Prevents running the loop with placeholder values in config.sh.

validate_config() {
  local errors=()
  [[ "$TENANCY_ID"      == *"REPLACE_ME"* ]] && errors+=("TENANCY_ID")
  [[ "$IMAGE_ID"        == *"REPLACE_ME"* ]] && errors+=("IMAGE_ID")
  [[ "$SUBNET_ID"       == *"REPLACE_ME"* ]] && errors+=("SUBNET_ID")
  [[ "$AVAIL_DOMAIN"    == *"REPLACE_ME"* ]] && errors+=("AVAIL_DOMAIN")
  [[ "$SSH_PUBLIC_KEY"  == *"REPLACE_ME"* ]] && errors+=("SSH_PUBLIC_KEY")

  if [[ ${#errors[@]} -gt 0 ]]; then
    log_error "The following values in config.sh are not set:"
    for e in "${errors[@]}"; do log_error "  - $e"; done
    log_error ""
    log_error "Run './oracle_vps.sh --setup' to discover the required IDs."
    exit 1
  fi
}

# ── Provisioning loop ─────────────────────────────────────────────────────────

run_provisioning() {
  validate_config

  # Calculate max attempts (0 = unlimited)
  local max_attempts
  if [[ "$MAX_HOURS" -eq 0 ]]; then
    max_attempts=0   # handled as unlimited below
  else
    max_attempts=$(( MAX_HOURS * 3600 / REQUEST_INTERVAL ))
  fi

  local interval=$REQUEST_INTERVAL

  # Build the shape config JSON
  local shape_config
  shape_config=$(jq -cn --argjson c "$OCPUS" --argjson m "$RAM_GB" \
    '{"ocpus": $c, "memoryInGBs": $m}')

  log_section "=== Oracle Free ARM VPS Auto-Provisioner ==="
  log_info "Tenancy:   $TENANCY_ID"
  log_info "Image:     $IMAGE_ID"
  log_info "Subnet:    $SUBNET_ID"
  log_info "Domain:    $AVAIL_DOMAIN"
  log_info "Shape:     VM.Standard.A1.Flex (${OCPUS} OCPUs, ${RAM_GB} GB RAM)"
  [[ "$max_attempts" -eq 0 ]] \
    && log_info "Max runs:  unlimited" \
    || log_info "Max runs:  $max_attempts (~${MAX_HOURS}h)"
  log ""

  local i=0
  while true; do
    # Honour max_attempts when set
    if [[ "$max_attempts" -gt 0 && "$i" -ge "$max_attempts" ]]; then
      log_warn "Reached maximum attempts ($max_attempts). Exiting."
      break
    fi

    # Sleep between attempts (skip on the very first iteration)
    [[ "$i" -gt 0 ]] && sleep "$interval"

    local attempt=$(( i + 1 ))
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    if [[ "$max_attempts" -eq 0 ]]; then
      log "[$timestamp] Attempt $attempt"
    else
      log "[$timestamp] Attempt $attempt of $max_attempts"
    fi

    # Refresh the auth token every 10 attempts to survive long runs
    if [[ "$i" -gt 0 && $(( i % 10 )) -eq 0 ]]; then
      log_info "Refreshing auth token..."
      oci session refresh --profile "$OCI_PROFILE" 2>/dev/null || true
    fi

    # Build oci command as an array to safely handle arguments with spaces
    local cmd=(
      oci compute instance launch
      --no-retry
      --config-file "$OCI_CONFIG_FILE"
      --profile     "$OCI_PROFILE"
      --auth        security_token
      --compartment-id    "$TENANCY_ID"
      --availability-domain "$AVAIL_DOMAIN"
      --image-id    "$IMAGE_ID"
      --shape       "VM.Standard.A1.Flex"
      --shape-config "$shape_config"
      --subnet-id   "$SUBNET_ID"
    )
    if [[ -n "$SSH_PUBLIC_KEY" ]]; then
      local metadata
      metadata=$(jq -cn --arg key "$SSH_PUBLIC_KEY" '{"ssh_authorized_keys": $key}')
      cmd+=(--metadata "$metadata")
    fi

    # Run and capture both stdout and stderr
    local response
    response=$("${cmd[@]}" 2>&1) || true

    [[ "$SILENT" == "false" ]] && log_info "Raw response: $response"

    # ── Parse response ────────────────────────────────────────────────────

    local instance_id display_name http_status message
    instance_id=$(echo "$response" | jq -r '.data.id           // empty' 2>/dev/null || true)
    display_name=$(echo "$response" | jq -r '.data."display-name" // empty' 2>/dev/null || true)
    http_status=$(echo "$response"  | jq -r '.status           // empty' 2>/dev/null || true)
    message=$(echo "$response"      | jq -r '.message          // empty' 2>/dev/null || true)

    # ── Success ───────────────────────────────────────────────────────────
    if [[ -n "$instance_id" ]]; then
      log ""
      log_ok "Instance created!"
      log_ok "  Instance ID:  $instance_id"
      [[ -n "$display_name" ]] && log_ok "  Display name: $display_name"
      log ""
      log_ok "Check the Oracle Cloud console for SSH connection details."
      exit 0
    fi

    # ── Error handling ────────────────────────────────────────────────────
    case "$http_status" in
      429)
        interval=$(( interval + 1 ))
        log_warn "Rate limited (429). Increasing interval to ${interval}s."
        ;;
      401)
        log_error "Authentication failed (401) — session expired."
        log_error "Run:  oci session authenticate"
        exit 1
        ;;
      "")
        # No JSON status — API may have returned a plain-text error
        log_warn "No JSON status in response."
        [[ "$SILENT" == "false" ]] || log_warn "Raw: $response"
        ;;
      *)
        log_warn "Status $http_status: $message"
        ;;
    esac

    (( i++ )) || true
  done
}

# ── Entry point ───────────────────────────────────────────────────────────────

check_deps

case "${1:-}" in
  --setup | -s)
    run_setup
    ;;
  --help | -h)
    log "Usage: $0 [--setup | --help]"
    log "  (no args)   Start the provisioning loop"
    log "  --setup     Discover and display required config IDs"
    log "  --help      Show this help"
    ;;
  "")
    run_provisioning
    ;;
  *)
    log_error "Unknown option: $1"
    log_error "Run '$0 --help' for usage."
    exit 1
    ;;
esac
