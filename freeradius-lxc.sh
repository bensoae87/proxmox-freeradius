
#!/usr/bin/env bash
set -e

echo "=== Proxmox FreeRADIUS LXC Setup (Debian 12 Bookworm) ==="

# ---- Defaults ----
DEFAULT_CORES=2
DEFAULT_RAM=2048
DEFAULT_DISK=8
DEFAULT_HOSTNAME="freeradius"
DEFAULT_NET="dhcp"
DEFAULT_BRIDGE="vmbr0"
DEFAULT_CTID=$(pvesh get /cluster/nextid)

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

# ---- Debian template ----
TEMPLATE="debian-12-standard_12.2-1_amd64.tar.zst"
TEMPLATE_PATH="/var/lib/vz/template/cache/$TEMPLATE"

if [[ ! -f "$TEMPLATE_PATH" ]]; then
  echo "Downloading Debian 12 template..."
  pveam update
  pveam download local "$TEMPLATE"
fi

# ---- Create LXC ----
echo "Creating container $CTID..."
pct create "$CTID" "$TEMPLATE_PATH" \
  --hostname "$HOSTNAME" \
  --cores "$CORES" \
  --memory "$RAM" \
  --rootfs local-lvm:${DISK} \
  --net0 "$NETCONF" \
  --features keyctl=1,nesting=1 \
  --unprivileged 1 \
  --onboot 1

# ---- Start container ----
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

# ---- Configure test user ----
echo "Configuring default RADIUS user (radusr / radusr)..."
pct exec "$CTID" -- bash -c "
cat <<EOF >> /etc/freeradius/4.0/mods-config/files/authorize
radusr Cleartext-Password := \"radusr\"
EOF
"

# ---- Enable & restart ----
pct exec "$CTID" -- bash -c "
systemctl enable freeradius
systemctl restart freeradius
systemctl status freeradius --no-pager
"

# ---- Final info ----
echo
echo "=== Setup Complete ==="
echo "Container ID: $CTID"
echo "Hostname: $HOSTNAME"
echo "RADIUS test user:"
echo "  Username: radusr"
echo "  Password: radusr"
echo
echo "To test:"
echo "  pct exec $CTID -- radtest radusr radusr localhost 0 testing123"
