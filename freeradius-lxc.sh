#!/usr/bin/env bash
set -euo pipefail

# ---- Requirements ----
if ! command -v pct >/dev/null; then
  echo "This script must be run on a Proxmox host"
  exit 1
fi

if ! command -v whiptail >/dev/null; then
  apt update && apt install -y whiptail
fi

# ---- Defaults ----
CTID_DEFAULT=$(pvesh get /cluster/nextid)
HOSTNAME_DEFAULT="freeradius"
CPU_DEFAULT="2"
RAM_DEFAULT="2048"
DISK_DEFAULT="8"
BRIDGE_DEFAULT="vmbr0"

# ---- Welcome ----
whiptail --title "FreeRADIUS Installer" \
  --msgbox "This installer will create a Debian 12 LXC and install FreeRADIUS.\n\nProceed?" 10 60

# ---- CTID ----
CTID=$(whiptail --title "Container ID" --inputbox \
"Enter Container ID:" 8 60 "$CTID_DEFAULT" 3>&1 1>&2 2>&3)

# ---- Hostname ----
HOSTNAME=$(whiptail --title "Hostname" --inputbox \
"Enter hostname:" 8 60 "$HOSTNAME_DEFAULT" 3>&1 1>&2 2>&3)

# ---- Resources ----
CPU=$(whiptail --title "CPU Cores" --inputbox \
"Number of CPU cores:" 8 60 "$CPU_DEFAULT" 3>&1 1>&2 2>&3)

RAM=$(whiptail --title "Memory" --inputbox \
"Memory in MB:" 8 60 "$RAM_DEFAULT" 3>&1 1>&2 2>&3)

DISK=$(whiptail --title "Disk Size" --inputbox \
"Disk size in GB:" 8 60 "$DISK_DEFAULT" 3>&1 1>&2 2>&3)

# ---- Network ----
NETTYPE=$(whiptail --title "Networking" --menu \
"Select network type:" 12 60 2 \
"dhcp" "Automatic (DHCP)" \
"static" "Manual (Static IP)" 3>&1 1>&2 2>&3)

if [[ "$NETTYPE" == "static" ]]; then
  IPADDR=$(whiptail --title "IP Address" --inputbox \
"Enter IP (e.g. 192.168.1.50/24):" 8 60 "" 3>&1 1>&2 2>&3)

  GATEWAY=$(whiptail --title "Gateway" --inputbox \
"Enter Gateway:" 8 60 "" 3>&1 1>&2 2>&3)

  NETCONF="name=eth0,bridge=$BRIDGE_DEFAULT,ip=$IPADDR,gw=$GATEWAY"
else
  NETCONF="name=eth0,bridge=$BRIDGE_DEFAULT,ip=dhcp"
fi

# ---- Summary ----
whiptail --title "Confirm Settings" --yesno \
"Container ID: $CTID
Hostname: $HOSTNAME
CPU: $CPU
RAM: $RAM MB
Disk: $DISK GB
Network: $NETTYPE

Continue?" 14 60

# ---- Storage Detection ----
STORAGE=$(pvesm status -content vztmpl 2>/dev/null | awk 'NR>1 {print $1}' | head -n 1)
if [[ -z "$STORAGE" ]]; then
  whiptail --msgbox "No storage found that supports LXC templates (vztmpl)." 8 60
  exit 1
fi

# ---- Template ----
pveam update
TEMPLATE=$(pveam available --section system | awk '/debian-12-standard/ {print $2}' | sort -V | tail -n 1)

# ---- Progress ----
{
  echo "10"; echo "Downloading Debian template..."
  pveam download "$STORAGE" "$TEMPLATE"

  echo "30"; echo "Creating container..."
  pct create "$CTID" "$STORAGE:vztmpl/$TEMPLATE" \
    --hostname "$HOSTNAME" \
    --cores "$CPU" \
    --memory "$RAM" \
    --rootfs ${STORAGE}:${DISK} \
    --net0 "$NETCONF" \
    --features keyctl=1,nesting=1 \
    --unprivileged 1 \
    --onboot 1

  echo "50"; echo "Starting container..."
  pct start "$CTID"
  sleep 8

  echo "70"; echo "Installing FreeRADIUS..."
  pct exec "$CTID" -- bash -c "
    apt update &&
    apt -y upgrade &&
    apt -y install freeradius freeradius-utils
  "

  echo "90"; echo "Configuring test user..."
  pct exec "$CTID" -- bash -c "
cat <<EOF >> /etc/freeradius/4.0/mods-config/files/authorize
radusr Cleartext-Password := \"radusr\"
EOF
systemctl enable freeradius
systemctl restart freeradius
  "

  echo "100"; echo "Done."
} | whiptail --gauge "Installing FreeRADIUS..." 6 60 0

# ---- Done ----
whiptail --title "Installation Complete" --msgbox \
"FreeRADIUS has been installed successfully.

Test user:
  Username: radusr
  Password: radusr

Test command:
  pct exec $CTID -- radtest radusr radusr localhost 0 testing123
" 14 70
