#!/usr/bin/env bash
# Proxmox VE Helper Script: FreeRADIUS LXC

source <(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/build.func)

header_info
check_root
check_pve

APP="FreeRADIUS"
var_disk="8"
var_cpu="2"
var_ram="2048"
var_os="debian"
var_version="12"
var_unprivileged="1"
var_features="keyctl=1,nesting=1"
var_tags="radius;network"
var_hostname="freeradius"

default_settings

function install_freeradius() {
  msg_info "Installing FreeRADIUS"
  pct exec "$CTID" -- bash -c "
    apt update &&
    apt -y upgrade &&
    apt -y install freeradius freeradius-utils
  "
  msg_ok "FreeRADIUS installed"
}

function configure_freeradius() {
  msg_info "Configuring FreeRADIUS test user"
  pct exec "$CTID" -- bash -c "
cat <<EOF >> /etc/freeradius/4.0/mods-config/files/authorize
radusr Cleartext-Password := \"radusr\"
EOF
systemctl enable freeradius
systemctl restart freeradius
  "
  msg_ok "FreeRADIUS configured"
}

start
build_container
install_freeradius
configure_freeradius
finish

msg_ok "Installation complete!"
echo
echo "Test with:"
echo "  pct exec $CTID -- radtest radusr radusr localhost 0 testing123"
