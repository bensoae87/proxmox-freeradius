#!/usr/bin/env bash
set -euo pipefail

echo "=== Proxmox FreeRADIUS LXC Setup (Debian 12 Bookworm) ==="

# ---- Safety Check ----
if ! command -v pct >/dev/null; then
  echo "❌ This script must be run on a Proxmox host"
  exit 1
fi

# ---- Ensure jq is available (Proxmox 8 may not ship it) ----
if ! command -v jq >/dev/null; then
  echo "jq not found — installing..."
  apt update
  apt install -y jq
fi

# ---- Defaults ----
DEFAULT_CORES=2
DEFAULT_RAM=2048
DEFAULT_DISK=8
DEFAULT_HOSTNAME="freeradius"
DEFAULT_NET="dhcp"
DEFAULT_BRIDGE="vmbr0"
DEFAULT_CTID=$(pvesh get /cluster/nextid)

# ---- Confirmation ----
read -rp "This will create a new LXC container. Continue? [y/N]: " CONFIRM
[[ "$CONFIRM" =~ ^[Yy]$ ]] || exit 1

# ---- Prompts ----
read -rp "Container ID [$DEFAULT_CTID]: " CTID
CTID=${CTID:-$DEFAULT_CTID}

read -rp "Hostname [$DEFAULT_HOSTNAME]: " HOSTNAME
HOSTNAME=${HOSTNAME:-$DEFAULT_HOSTNAME}

read -rp "CPU cores [$DEFAULT_CORES]: " CORES
CORES=${CORES:-$DEFAULT_CORES}

read -rp "RAM in MB [$DEFAULT_RAM]: " RAM
RAM=${RAM:-$DEFAULT_RAM}

read -rp "Disk size in GB [$DEFAULT_DISK]: " DISK
DISK=${DISK:-$DEFAULT_DISK}

read -rp "Network type (dhcp/static) [$DEFAULT_NET]: " NETTYPE
NETTYPE=${NETTYPE:-$DEFAULT_NET}

BRIDGE="$DEFAULT_BRIDGE"

if [[ "$NETTYPE" == "static" ]]; then
  read -rp "IP address (e.g. 192.168.1.50/24): " IPADDR
  read -rp "Gateway (e.g. 192.168.1.1): " GATEWAY
  NETCONF="name=eth0,bridge=$BRIDGE,ip=$IPADDR,gw=$GATEWAY"
else
  NETCONF="name=eth0,bridge=$BRIDGE,ip=dhcp"
fi

# ---- Detect Active Storage Supporting LXC Templates ----
echo "Detecting active storage that supports LXC templates (vztmpl)..."

STORAGE=$(pvesh get /storage --output-format json \
  | jq -r '.[] | select(.active==1) | select(.content[]?=="vztmpl") | .storage' \
  | head -n 1)

if [[ -z "$STORAGE" ]]; then
  echo "❌ No ACTIVE storage found that supports LXC templates (vztmpl)"
  echo "Check with: pvesh get /storage --output-format json | jq"
  exit 1
fi

echo "Using storage: $STORAGE"

# ---- Find Latest Debian 12 Template ----
echo "Looking up latest Debian 12 template..."
pveam update

TEMPLATE=$(pveam available --section system \
  | awk '/debian-12-standard/ {print $2}' \
  | sort -V \
  | tail -n 1)

if [[ -z "$TEMPLATE" ]]; then
  echo "❌ Could not find Debian 12 template"
  exit 1
fi

echo "Using template: $TEMPLATE"
pveam download "$STORAGE" "$TEMPLATE"

# ---- Create LXC ----
echo "Creating container $CTID..."
pct create "$CTID" "$STORAGE:vztmpl/$TEMPLATE" \
  --hostname "$HOSTNAME" \
  --cores "$CORES" \
  --memory "$RAM" \
  --rootfs ${STORAGE}:${DISK} \
  --net0 "$NETCONF" \
  --features keyctl=1,nesting=1 \
  --unprivileged 1 \
  --onboot 1

# ---- Start Container ----
pct start "$CTID"
echo "Waiting for container to boot..."
sleep 8

# ---- Install FreeRADIUS ----
echo "Installing FreeRADIUS 4..."
pct exec "$CTID" -- bash -c "
set -e
apt update
apt -y upgrade
apt -y install freeradius freeradius-utils
"

# ---- Configure Default RADIUS User ----
echo "Configuring default RADIUS user (radusr / radusr)..."
pct exec "$CTID" -- bash -c "
cat <<EOF >> /etc/freeradius/4.0/mods-config/files/authorize
radusr Cleartext-Password := \"radusr\"
EOF
"

# ---- Enable & Restart ----
pct exec "$CTID" -- bash -c "
systemctl enable freeradius
systemctl restart freeradius
"

# ---- Final Output ----
echo
echo "=== Setup Complete ==="
echo "Container ID : $CTID"
echo "Hostname     : $HOSTNAME"
echo "RADIUS User  : radusr"
echo "Password    : radusr"
echo
echo "Test with:"
echo "  pct exec $CTID -- radtest radusr radusr localhost 0 testing123"
