#!/usr/bin/env bash
source <(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/build.func)

# App metadata
APP="FreeRADIUS + daloRADIUS"
var_tags="radius,freeradius,daloradius,auth"
var_cpu="2"
var_ram="2048"
var_disk="8"
var_os="debian"
var_version="12"
var_unprivileged="0"     # 0 = Privileged (YES)
var_dhcp="1"             # 1 = DHCP (YES)
var_hostname="freeradius"

# UI
header_info
echo "This will create a FreeRADIUS + daloRADIUS LXC container."
echo "Default Linux user: radusr / radusr"
echo ""

# Create container
variables
color
catch_errors
start
build_container

# Container setup
msg_info "Setting root password"
pct exec $CTID -- bash -c "echo root:radusr | chpasswd"

msg_info "Creating radusr user"
pct exec $CTID -- bash -c "
useradd -m -s /bin/bash radusr &&
echo radusr:radusr | chpasswd &&
usermod -aG sudo radusr
"

msg_info "Updating container"
pct exec $CTID -- bash -c "apt update && apt -y upgrade"

msg_info "Installing dependencies"
pct exec $CTID -- bash -c "
apt install -y \
freeradius freeradius-mysql \
mariadb-server \
apache2 \
php php-mysql php-gd php-xml php-mbstring php-curl php-zip \
git unzip
"

msg_info "Configuring MariaDB"
pct exec $CTID -- bash -c "
systemctl enable --now mariadb &&
mysql -e \"
CREATE DATABASE radius;
CREATE USER 'radius'@'localhost' IDENTIFIED BY 'radius';
GRANT ALL PRIVILEGES ON radius.* TO 'radius'@'localhost';
FLUSH PRIVILEGES;
\"
"

msg_info "Importing FreeRADIUS schema"
pct exec $CTID -- bash -c "
mysql radius < /etc/freeradius/3.0/mods-config/sql/main/mysql/schema.sql
"

msg_info "Installing daloRADIUS"
pct exec $CTID -- bash -c "
cd /var/www/html &&
git clone https://github.com/lirantal/daloradius.git &&
chown -R www-data:www-data daloradius &&
chmod -R 755 daloradius
"

msg_info "Configuring daloRADIUS"
pct exec $CTID -- bash -c "
cp /var/www/html/daloradius/library/daloradius.conf.php.sample \
   /var/www/html/daloradius/library/daloradius.conf.php &&
sed -i \"s/'DB_PASSWORD' => '.*'/'DB_PASSWORD' => 'radius'/\" \
   /var/www/html/daloradius/library/daloradius.conf.php
"

msg_info "Enabling services"
pct exec $CTID -- bash -c "
systemctl enable --now freeradius apache2
"

msg_ok "Installation complete!"

echo ""
echo "Access daloRADIUS at:"
echo "  http://<container-ip>/daloradius"
echo ""
echo "Default daloRADIUS credentials:"
echo "  username: administrator"
echo "  password: radius"
echo ""
echo "Linux user:"
echo "  radusr / radusr"
echo ""

exit 0
