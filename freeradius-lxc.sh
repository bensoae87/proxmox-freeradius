#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# FreeRADIUS + daloRADIUS Installer (Proxmox LXC Safe)
# -----------------------------------------------------------------------------

set -e

source <(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/build.func)

APP="FreeRADIUS + daloRADIUS"
var_tags="radius;daloradius"
var_cpu="2"
var_ram="2048"
var_disk="8"
var_os="debian"
var_version="12"
var_unprivileged="0"
var_hostname="freeradius"

start
build_container

msg_info "Installing packages"

pct exec "$CTID" -- bash -c "
export DEBIAN_FRONTEND=noninteractive

apt update
apt -y upgrade
apt -y install freeradius freeradius-utils mariadb-server \
               apache2 php php-mysql php-gd php-curl php-zip \
               php-mbstring php-xml git unzip
"

msg_info "Applying systemd overrides for LXC compatibility"

pct exec "$CTID" -- bash -c "
set -e

for svc in freeradius mariadb apache2; do
  mkdir -p /etc/systemd/system/\$svc.service.d
  cat <<EOF > /etc/systemd/system/\$svc.service.d/override.conf
[Service]
PrivateTmp=no
ProtectSystem=off
ProtectHome=off
NoNewPrivileges=no
RestrictNamespaces=no
EOF
done

systemctl daemon-reexec
systemctl daemon-reload
"

msg_info "Starting services"

pct exec "$CTID" -- bash -c "
systemctl enable mariadb apache2 freeradius
systemctl start mariadb apache2 freeradius
"

msg_info "Configuring FreeRADIUS user"

pct exec "$CTID" -- bash -c "
cat <<EOF >> /etc/freeradius/3.0/mods-config/files/authorize
radusr Cleartext-Password := \"radusr\"
EOF

systemctl restart freeradius
"

msg_info "Configuring MariaDB and daloRADIUS"

pct exec "$CTID" -- bash -c "
mysql -e \"CREATE DATABASE IF NOT EXISTS radius;\"
mysql -e \"CREATE USER IF NOT EXISTS 'radius'@'localhost' IDENTIFIED BY 'radius';\"
mysql -e \"GRANT ALL PRIVILEGES ON radius.* TO 'radius'@'localhost';\"
mysql -e \"FLUSH PRIVILEGES;\"

cd /var/www/html
git clone https://github.com/lirantal/daloradius.git || true
chown -R www-data:www-data daloradius

mysql radius < daloradius/contrib/db/fr2-mysql-daloradius-and-freeradius.sql

cp daloradius/library/daloradius.conf.php.sample \
   daloradius/library/daloradius.conf.php

sed -i \"s/DB_USER.*/DB_USER = 'radius';/\" daloradius/library/daloradius.conf.php
sed -i \"s/DB_PASSWORD.*/DB_PASSWORD = 'radius';/\" daloradius/library/daloradius.conf.php
sed -i \"s/DB_NAME.*/DB_NAME = 'radius';/\" daloradius/library/daloradius.conf.php

systemctl restart apache2
"

msg_ok "Installation complete"

IP=$(pct exec "$CTID" -- hostname -I | awk '{print $1}')

echo
echo "------------------------------------------------------------"
echo " FreeRADIUS + daloRADIUS READY"
echo "------------------------------------------------------------"
echo " Container ID : $CTID"
echo " IP Address   : $IP"
echo
echo " RADIUS Test:"
echo "   radtest radusr radusr $IP 0 testing123"
echo
echo " daloRADIUS UI:"
echo "   http://$IP/daloradius"
echo "   User: administrator"
echo "   Pass: radius"
echo "------------------------------------------------------------"
