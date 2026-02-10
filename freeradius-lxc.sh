#!/usr/bin/env bash
source <(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/build.func)

header_info
check_root
check_pve

APP="FreeRADIUS + daloRADIUS"
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

function update_container() {
  msg_info "Updating container OS"
  pct exec "$CTID" -- bash -c "apt update && apt -y upgrade"
  msg_ok "OS updated"
}

function install_packages() {
  msg_info "Installing FreeRADIUS, Apache, PHP, MariaDB"
  pct exec "$CTID" -- bash -c "
    apt install -y \
      freeradius freeradius-utils \
      apache2 mariadb-server \
      php php-cli php-common libapache2-mod-php \
      php-mysql php-gd php-curl php-zip php-mbstring php-xml \
      unzip git curl
  "
  msg_ok "Packages installed"
}

function configure_apache_php() {
  msg_info "Configuring Apache for PHP"
  pct exec "$CTID" -- bash -c "
    sed -i 's|DirectoryIndex .*|DirectoryIndex index.php index.html index.cgi index.pl index.xhtml index.htm|' /etc/apache2/mods-enabled/dir.conf
    a2enmod php8.2
    systemctl restart apache2
  "
  msg_ok "Apache configured"
}

function install_daloradius() {
  msg_info "Installing daloRADIUS"
  pct exec "$CTID" -- bash -c "
    cd /var/www/html
    git clone https://github.com/lirantal/daloradius.git
    chown -R www-data:www-data daloradius
    chmod -R 755 daloradius
  "
  msg_ok "daloRADIUS installed"
}

function configure_database() {
  msg_info "Configuring MariaDB for daloRADIUS"
  pct exec "$CTID" -- bash -c "
    mysql -u root <<EOF
CREATE DATABASE radius;
CREATE USER 'radius'@'localhost' IDENTIFIED BY 'radius';
GRANT ALL PRIVILEGES ON radius.* TO 'radius'@'localhost';
FLUSH PRIVILEGES;
EOF
    mysql -u radius -pradius radius < /var/www/html/daloradius/contrib/db/mysql-daloradius.sql
    mysql -u radius -pradius radius < /var/www/html/daloradius/contrib/db/mysql-radius.sql
  "
  msg_ok "Database configured"
}

function configure_daloradius() {
  msg_info "Configuring daloRADIUS"
  pct exec "$CTID" -- bash -c "
    cp /var/www/html/daloradius/library/daloradius.conf.php.sample \
       /var/www/html/daloradius/library/daloradius.conf.php

    sed -i \"s/DB_USER.*/DB_USER', 'radius');/\" /var/www/html/daloradius/library/daloradius.conf.php
    sed -i \"s/DB_PASSWORD.*/DB_PASSWORD', 'radius');/\" /var/www/html/daloradius/library/daloradius.conf.php
    sed -i \"s/DB_NAME.*/DB_NAME', 'radius');/\" /var/www/html/daloradius/library/daloradius.conf.php
  "
  msg_ok "daloRADIUS configured"
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

function start_services() {
  msg_info "Enabling services"
  pct exec "$CTID" -- systemctl enable apache2 mariadb
  pct exec "$CTID" -- systemctl restart apache2 mariadb
  msg_ok "Services started"
}

start
build_container
update_container
install_packages
configure_apache_php
install_daloradius
configure_database
configure_daloradius
configure_freeradius
start_services
finish

msg_ok "Installation complete!"
echo
echo "daloRADIUS UI:"
echo "  http://<container-ip>/daloradius/"
echo
echo "Login:"
echo "  administrator / radius"
echo
echo "RADIUS test:"
echo "  radusr / radusr"
