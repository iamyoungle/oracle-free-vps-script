#!/usr/bin/env bash
# =============================================================================
# Oracle Free ARM VPS — Configuration
# =============================================================================
# 1. Run setup to discover your IDs:   ./oracle_vps.sh --setup
# 2. Fill in the values below
# 3. Start provisioning:               ./oracle_vps.sh
# =============================================================================

# ── Required ─────────────────────────────────────────────────────────────────

# Your OCI Tenancy OCID
# Oracle Cloud → Profile icon → Tenancy → Tenancy Information → Copy OCID
TENANCY_ID="ocid1.tenancy.oc1..REPLACE_ME"

# ARM image OCID (must be aarch64, e.g. Canonical Ubuntu 22.04 aarch64)
# Run --setup to list available images
IMAGE_ID="ocid1.image.oc1..REPLACE_ME"

# Subnet OCID inside your VCN
# Run --setup to list available subnets
SUBNET_ID="ocid1.subnet.oc1..REPLACE_ME"

# Availability Domain (e.g. "IGuL:CA-TORONTO-1-AD-1")
# Run --setup to list available domains
AVAIL_DOMAIN="REPLACE_ME"

# Your SSH public key (paste the full key line, e.g. "ssh-rsa AAAA... user@host")
SSH_PUBLIC_KEY="ssh-rsa REPLACE_ME"

# ── VM Specs ─────────────────────────────────────────────────────────────────

OCPUS=4      # CPU cores  (free-tier max: 4)
RAM_GB=24    # Memory GB  (free-tier max: 24)

# ── OCI Authentication ───────────────────────────────────────────────────────

OCI_CONFIG_FILE="$HOME/.oci/config"

# ── Retry Behaviour ──────────────────────────────────────────────────────────

REQUEST_INTERVAL=60   # Seconds between each attempt

# ── Output ───────────────────────────────────────────────────────────────────

SILENT=true   # true = concise output; false = show full API responses
