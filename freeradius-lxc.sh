#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# FreeRADIUS + daloRADIUS LXC Installer (Proxmox Community Style)
# -----------------------------------------------------------------------------

set -e

# Load Proxmox community build framework
source <(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/build.func)

# -----------------------------------------------------------------------------
# App Metadata
# -----------------------------------------------------------------------------
APP="FreeRADIUS + daloRADIUS"
var_tags="radius;daloradius;auth"
var_cpu="2"
var_ram="2048"
var_disk="8"
var_os="debian"
var_version="12"
var_unprivileged="0"     # REQUIRED for FreeRADIUS
var_hostname="freeradius"

# -----------------------------------------------------------------------------
# Build the container
# -----------------------------------------------------------------------------
start
build_container

# -----------------------------------------------------------------------------
# Install FreeRADIUS + daloRADIUS
# -----------------------------------------------------------------------------
msg_info "Installing FreeRADIUS and daloRADIUS"

pct exec "$CTID" -- bash -c "
set -e

export DEBIAN_FRONTEND=noninteractive

apt update
apt -y upgrade

# Base packages
apt -y install freeradius freeradius-utils mariadb-server \
               apache2 php php-mysql php-gd php-curl php-zip \
               php-mbstring php-xml git unzip

# Enable services
systemctl enable mariadb apache2 freeradius
systemctl start mariadb apache2

# FreeRADIUS test user
cat <<EOF >> /etc/freeradius/3.0/mods-config/files/authorize
radusr Cleartext-Password := \"radusr\"
EOF

# Restart FreeRADIUS
systemctl restart freeradius

# Secure MariaDB (minimal)
mysql -e \"CREATE DATABASE radius;\"
mysql -e \"CREATE USER 'radius'@'localhost' IDENTIFIED BY 'radius';\"
mysql -e \"GRANT ALL PRIVILEGES ON radius.* TO 'radius'@'localhost';\"
mysql -e \"FLUSH PRIVILEGES;\"

# Install daloRADIUS
cd /var/www/html
git clone https://github.com/lirantal/daloradius.git
chown -R www-data:www-data daloradius

# Import daloRADIUS schema
mysql radius < daloradius/contrib/db/fr2-mysql-daloradius-and-freeradius.sql

# Configure daloRADIUS
cp daloradius/library/daloradius.conf.php.sample \
   daloradius/library/daloradius.conf.php

sed -i \"s/DB_USER.*/DB_USER = 'radius';/\" daloradius/library/daloradius.conf.php
sed -i \"s/DB_PASSWORD.*/DB_PASSWORD = 'radius';/\" daloradius/library/daloradius.conf.php
sed -i \"s/DB_NAME.*/DB_NAME = 'radius';/\" daloradius/library/daloradius.conf.php

systemctl restart apache2
"

msg_ok "FreeRADIUS + daloRADIUS installed successfully"

# -----------------------------------------------------------------------------
# Final Info
# -----------------------------------------------------------------------------
IP=$(pct exec "$CTID" -- hostname -I | awk '{print $1}')

echo
echo "------------------------------------------------------------"
echo " FreeRADIUS + daloRADIUS READY"
echo "------------------------------------------------------------"
echo " Container ID : $CTID"
echo " Hostname     : freeradius"
echo " IP Address   : $IP"
echo
echo " RADIUS Test:"
echo "   radtest radusr radusr $IP 0 testing123"
echo
echo " daloRADIUS Web UI:"
echo "   http://$IP/daloradius"
echo "   Username: administrator"
echo "   Password: radius"
echo "------------------------------------------------------------"
