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
#   Then:           Configure OCI API key in ~/.oci/config (or OCI_CONFIG_FILE)
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
  echo "--config-file $OCI_CONFIG_FILE --profile "DEFAULT" --auth api_key"
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

# ── Pre-flight checks ─────────────────────────────────────────────────────────
# Checks if an instance of the target shape already exists.

check_existing_instance() {
  log_info "Checking for existing VM.Standard.A1.Flex instances..."
  
  # Fetch running/provisioning instances with the target shape
  # shellcheck disable=SC2046
  local existing_instances
  existing_instances=$(oci compute instance list \
    -c "$TENANCY_ID" \
    $(oci_auth_flags) \
    --lifecycle-state RUNNING \
    --lifecycle-state PROVISIONING \
    --lifecycle-state STARTING \
    2>/dev/null | jq -r '
      .data[]? 
      | select(.shape == "VM.Standard.A1.Flex") 
      | .id
    ')

  if [[ -n "$existing_instances" ]]; then
    log_ok "An existing VM.Standard.A1.Flex instance was found!"
    log_ok "Instance ID(s):"
    for id in $existing_instances; do
      log_ok "  - $id"
    done
    log_ok "Exiting. No need to provision a new one."
    exit 0
  fi
}

# ── Provisioning loop ─────────────────────────────────────────────────────────

run_provisioning() {
  validate_config
  check_existing_instance

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
  log_info "Mode:      Indefinite (API Key Authentication)"
  log ""

  local i=0
  SECONDS=0 # Built-in bash variable tracking seconds since script start

  while true; do
    # Sleep between attempts (skip on the very first iteration)
    [[ "$i" -gt 0 ]] && sleep "$interval"

    local attempt=$(( i + 1 ))
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    # Calculate elapsed time
    local elapsed_h=$(( SECONDS / 3600 ))
    local elapsed_m=$(( (SECONDS % 3600) / 60 ))
    local elapsed_s=$(( SECONDS % 60 ))
    local elapsed_str=$(printf "%02dh:%02dm:%02ds" $elapsed_h $elapsed_m $elapsed_s)

    log "[$timestamp] Attempt $attempt | Elapsed: $elapsed_str"

    # API Keys don't expire, so we don't need to refresh tokens anymore.
    # We can just keep requesting until we get the instance.

    # Build oci command as an array to safely handle arguments with spaces
    local cmd=(
      oci compute instance launch
      --no-retry
      --config-file "$OCI_CONFIG_FILE"
      --profile     "DEFAULT"
      --auth        api_key
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
        log_error "Authentication failed (401) — check your API key setup."
        log_error "Please ensure ~/.oci/config is correctly configured."
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
