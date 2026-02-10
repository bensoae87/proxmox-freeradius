#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# FreeRADIUS LXC Installer for Proxmox
# Uses the official Proxmox community-scripts build framework
# -----------------------------------------------------------------------------

set -e

# Load community build functions (same as tasmoadmin.sh)
source <(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/build.func)

# -----------------------------------------------------------------------------
# App Metadata (used by the framework)
# -----------------------------------------------------------------------------
APP="FreeRADIUS"
var_tags="radius;auth"
var_cpu="2"
var_ram="2048"
var_disk="8"
var_os="debian"
var_version="12"
var_unprivileged="1"
var_hostname="freeradius"

# -----------------------------------------------------------------------------
# Create the container
# -----------------------------------------------------------------------------
start
build_container

# -----------------------------------------------------------------------------
# Post-install configuration inside the container
# -----------------------------------------------------------------------------
msg_info "Installing FreeRADIUS 4"

pct exec "$CTID" -- bash -c "
set -e

apt update
apt -y upgrade
apt -y install freeradius freeradius-utils

echo 'Adding default RADIUS user: radusr / radusr'
cat <<EOF >> /etc/freeradius/4.0/mods-config/files/authorize
radusr Cleartext-Password := \"radusr\"
EOF

systemctl enable freeradius
systemctl restart freeradius
"

msg_ok "FreeRADIUS installation complete"

# -----------------------------------------------------------------------------
# Final message
# -----------------------------------------------------------------------------
IP=$(pct exec "$CTID" -- hostname -I | awk '{print $1}')

echo
echo "------------------------------------------------------------"
echo " FreeRADIUS LXC is ready"
echo "------------------------------------------------------------"
echo " Container ID : $CTID"
echo " Hostname     : freeradius"
echo " IP Address   : $IP"
echo
echo " Test command:"
echo "   radtest radusr radusr $IP 0 testing123"
echo "------------------------------------------------------------"
