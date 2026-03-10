# Oracle Free ARM VPS — Auto-Provisioner

Oracle Cloud's free-tier ARM instances (**4 OCPUs, 24 GB RAM, always free**) are
almost always "out of capacity" when you try to create them manually.
This script works around that by repeatedly sending the create request until
one succeeds — usually within a few hours.

---

## How it works

1. Calls `oci compute instance launch` every 60 seconds (configurable)
2. Parses the JSON response to detect success, rate-limiting, or auth errors
3. Refreshes the OCI session token every 10 attempts to survive long runs
4. Exits immediately when the instance is created

---

## Prerequisites

### 1. Install OCI CLI and jq

**macOS**
```bash
brew install oci-cli jq
```

**Debian / Ubuntu**
```bash
sudo apt install jq
pip install oci-cli
```

**RHEL / Fedora / CentOS**
```bash
sudo dnf install jq        # or: sudo yum install jq
pip install oci-cli
```

> Full OCI CLI install guide:
> https://docs.oracle.com/en-us/iaas/Content/API/SDKDocs/cliinstall.htm

### 2. Authenticate with OCI

```bash
oci session authenticate
```

- Choose your home region (e.g. `ca-toronto-1`)
- When prompted for a profile name, enter `DEFAULT` (or whatever you set `OCI_PROFILE` to in `config.sh`)
- A browser window will open — log in with your Oracle Cloud account

> Sessions expire after **24 hours**. Re-run this command when they do.

---

## Setup

### Step 1 — Clone and enter the project

```bash
git clone https://github.com/yourname/oracle-free-vps-script
cd oracle-free-vps-script
chmod +x oracle_vps.sh
```

### Step 2 — Find your Tenancy OCID

Oracle Cloud console → top-right profile icon →
**Tenancy: `<your-name>`** → **Tenancy Information** → **Copy OCID**

Paste it into `config.sh`:

```bash
TENANCY_ID="ocid1.tenancy.oc1..xxxxxxxxxxxx"
```

### Step 3 — Discover the remaining IDs

```bash
./oracle_vps.sh --setup
```

This prints all available ARM images, subnets, and availability domains from
your account. Copy the relevant values into `config.sh`.

### Step 4 — Edit config.sh

```bash
# Minimum required fields:
TENANCY_ID="ocid1.tenancy.oc1..xxxx"
IMAGE_ID="ocid1.image.oc1..xxxx"       # aarch64 image (e.g. Ubuntu 22.04)
SUBNET_ID="ocid1.subnet.oc1..xxxx"
AVAIL_DOMAIN="IGuL:CA-TORONTO-1-AD-1"
SSH_PUBLIC_KEY="ssh-rsa AAAA... user@host"
```

### Step 5 — Start provisioning

```bash
./oracle_vps.sh
```

The script will keep trying until it succeeds or `MAX_HOURS` is reached.

---

## File structure

```
oracle-free-vps-script/
├── config.sh        ← All user settings live here (edit this)
└── oracle_vps.sh    ← Main script (no edits needed)
```

---

## config.sh reference

| Variable | Default | Description |
|---|---|---|
| `TENANCY_ID` | *(required)* | Your OCI Tenancy OCID |
| `IMAGE_ID` | *(required)* | OCID of the ARM image to use |
| `SUBNET_ID` | *(required)* | OCID of the subnet to attach to |
| `AVAIL_DOMAIN` | *(required)* | Availability domain name |
| `SSH_PUBLIC_KEY` | *(required)* | SSH public key for instance access |
| `OCPUS` | `4` | Number of CPU cores (free-tier max: 4) |
| `RAM_GB` | `24` | Memory in GB (free-tier max: 24) |
| `OCI_PROFILE` | `DEFAULT` | OCI CLI profile name |
| `OCI_CONFIG_FILE` | `~/.oci/config` | Path to OCI config file |
| `REQUEST_INTERVAL` | `60` | Seconds between each attempt |
| `MAX_HOURS` | `24` | Stop after N hours (`0` = run indefinitely) |
| `SILENT` | `true` | `true` = concise output; `false` = show raw API responses |

---

## Usage

```
./oracle_vps.sh            Start the provisioning loop
./oracle_vps.sh --setup    Discover and display required config IDs
./oracle_vps.sh --help     Show help
```

---

## Running in the background (optional)

To keep running after you close your terminal:

```bash
# Using nohup
nohup ./oracle_vps.sh > oracle_vps.log 2>&1 &
echo "PID: $!"

# Follow the log
tail -f oracle_vps.log
```

Or with `screen`:

```bash
screen -S oracle
./oracle_vps.sh
# Detach: Ctrl+A then D
# Reattach: screen -r oracle
```

---

## Troubleshooting

**"Authentication failed (401)"**
Your session has expired. Re-authenticate:
```bash
oci session authenticate
```

**"Missing required tools: oci jq"**
Install the prerequisites listed at the top of this README.

**Script keeps running but never succeeds**
Capacity in your region/availability domain is very limited. Try:
- Changing `AVAIL_DOMAIN` to a different domain (use `--setup` to list them)
- Setting `MAX_HOURS=0` to run indefinitely

**Want verbose output to debug responses?**
Set `SILENT=false` in `config.sh`.

---

## Credits

Based on [HotNoob/Oracle-Free-Arm-VPS-PS](https://github.com/HotNoob/Oracle-Free-Arm-VPS-PS) (PowerShell).
This is a macOS/Linux bash rewrite with a separate config file.
