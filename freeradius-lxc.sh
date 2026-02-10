#!/usr/bin/env bash
source <(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/build.func)

APP="FreeRADIUS + daloRADIUS"
var_tags="radius,freeradius,daloradius,auth"
var_cpu="2"
var_ram="2048"
var_disk="8"
var_os="debian"
var_version="12"
var_unprivileged="0"
var_dhcp="1"
var_hostname="freeradius"

header_info
echo "This will install FreeRADIUS with daloRADIUS (SQL-only auth)."
echo ""

DB_PASS="$(whiptail --passwordbox "Enter MariaDB password for FreeRADIUS/daloRADIUS" 10 60 3>&1 1>&2 2>&3)"
if [ -z "$DB_PASS" ]; then
  msg_error "Database password cannot be empty"
  exit 1
fi

variables
color
catch_errors
start
build_container

msg_info "Setting root and radusr passwords"
pct exec $CTID -- bash -c "
echo root:radusr | chpasswd &&
useradd -m -s /bin/bash radusr &&
echo radusr:radusr | chpasswd &&
usermod -aG sudo radusr
"

msg_info "Installing packages"
pct exec $CTID -- bash -c "
apt update &&
apt install -y freeradius freeradius-mysql mariadb-server apache2 \
php php-mysql php-gd php-xml php-mbstring php-curl git unzip
"

msg_info "Configuring MariaDB"
pct exec $CTID -- bash -c "
systemctl enable --now mariadb &&
mysql -e \"
CREATE DATABASE radius;
CREATE USER 'radius'@'localhost' IDENTIFIED BY '$DB_PASS';
GRANT ALL PRIVILEGES ON radius.* TO 'radius'@'localhost';
FLUSH PRIVILEGES;
\"
"

msg_info "Importing schemas"
pct exec $CTID -- bash -c "
mysql radius < /etc/freeradius/3.0/mods-config/sql/main/mysql/schema.sql
"

msg_info "Installing daloRADIUS"
pct exec $CTID -- bash -c "
cd /var/www/html &&
git clone https://github.com/lirantal/daloradius.git &&
chown -R www-data:www-data daloradius
"

msg_info "Importing daloRADIUS schema"
pct exec $CTID -- bash -c "
mysql radius < /var/www/html/daloradius/contrib/db/mysql-daloradius.sql
"

msg_info "Configuring daloRADIUS"
pct exec $CTID -- bash -c "
cp /var/www/html/daloradius/app/common/includes/daloradius.conf.php.sample \
   /var/www/html/daloradius/app/common/includes/daloradius.conf.php &&
sed -i \"
s/'DB_USER'.*/'DB_USER' => 'radius',/
s/'DB_PASSWORD'.*/'DB_PASSWORD' => '$DB_PASS',/
s/'DB_NAME'.*/'DB_NAME' => 'radius',/
s/'DB_HOST'.*/'DB_HOST' => 'localhost',/
\" /var/www/html/daloradius/app/common/includes/daloradius.conf.php
"

msg_info "Configuring FreeRADIUS SQL-only auth"
pct exec $CTID -- bash -c "
ln -s /etc/freeradius/3.0/mods-available/sql /etc/freeradius/3.0/mods-enabled/sql &&
rm -f /etc/freeradius/3.0/mods-enabled/files &&
sed -i \"
s/login = .*/login = \\\"radius\\\"/
s/password = .*/password = \\\"$DB_PASS\\\"/
s/radius_db = .*/radius_db = \\\"radius\\\"/
\" /etc/freeradius/3.0/mods-available/sql
"

msg_info "Adding test RADIUS client and user"
pct exec $CTID -- bash -c "
echo '
client testclient {
  ipaddr = 127.0.0.1
  secret = testing123
}
' >> /etc/freeradius/3.0/clients.conf &&

mysql radius -e \"
INSERT INTO radcheck (username, attribute, op, value)
VALUES ('testuser','Cleartext-Password',':=','testpass');
\"
"

msg_info "Starting services"
pct exec $CTID -- bash -c "
systemctl enable --now freeradius apache2
"

msg_ok "Installation complete!"

echo ""
echo "daloRADIUS:"
echo "  http://<container-ip>/daloradius"
echo "  admin / radius"
echo ""
echo "Test RADIUS user:"
echo "  testuser / testpass"
echo "  client secret: testing123"
echo ""
