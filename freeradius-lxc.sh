#!/usr/bin/env bash
set -euo pipefail

echo "=== Proxmox FreeRADIUS + daloRADIUS LXC (Debian 12) ==="

# ---- Safety Check ----
if ! command -v pct >/dev/null; then
  echo "❌ This script must be run on a Proxmox host"
  exit 1
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

# ---- Detect Template Storage ----
echo "Detecting storage that supports LXC templates..."
STORAGE=$(pvesm status -content vztmpl 2>/dev/null | awk 'NR>1 {print $1}' | head -n 1)

if [[ -z "$STORAGE" ]]; then
  echo "❌ No storage supports vztmpl"
  exit 1
fi

echo "Using storage: $STORAGE"

# ---- Debian Template ----
pveam update
TEMPLATE=$(pveam available --section system | awk '/debian-12-standard/ {print $2}' | sort -V | tail -n 1)
pveam download "$STORAGE" "$TEMPLATE"

# ---- Create LXC ----
pct create "$CTID" "$STORAGE:vztmpl/$TEMPLATE" \
  --hostname "$HOSTNAME" \
  --cores "$CORES" \
  --memory "$RAM" \
  --rootfs ${STORAGE}:${DISK} \
  --net0 "$NETCONF" \
  --features keyctl=1,nesting=1 \
  --unprivileged 1 \
  --onboot 1

pct start "$CTID"
sleep 8

# ---- Provision Inside Container ----
pct exec "$CTID" -- bash -c "
set -e

echo 'Installing base packages...'
apt update
apt -y upgrade
apt install -y \
  freeradius freeradius-utils \
  apache2 mariadb-server \
  php php-cli php-common libapache2-mod-php \
  php-mysql php-gd php-curl php-zip php-mbstring php-xml \
  unzip git curl

echo 'Fixing Apache DirectoryIndex...'
sed -i 's|DirectoryIndex .*|DirectoryIndex index.php index.html index.cgi index.pl index.xhtml index.htm|' /etc/apache2/mods-enabled/dir.conf
a2enmod php8.2
systemctl restart apache2

echo 'Installing daloRADIUS...'
cd /var/www/html
git clone https://github.com/lirantal/daloradius.git
chown -R www-data:www-data daloradius
chmod -R 755 daloradius

echo 'Configuring MariaDB...'
mysql -u root <<EOF
CREATE DATABASE radius;
CREATE USER 'radius'@'localhost' IDENTIFIED BY 'radius';
GRANT ALL PRIVILEGES ON radius.* TO 'radius'@'localhost';
FLUSH PRIVILEGES;
EOF

echo 'Importing daloRADIUS schema...'
mysql -u radius -pradius radius < /var/www/html/daloradius/contrib/db/mysql-daloradius.sql
mysql -u radius -pradius radius < /var/www/html/daloradius/contrib/db/mysql-radius.sql

echo 'Configuring daloRADIUS...'
cp /var/www/html/daloradius/library/daloradius.conf.php.sample \
   /var/www/html/daloradius/library/daloradius.conf.php

sed -i \"s/DB_USER.*/DB_USER', 'radius');/\" /var/www/html/daloradius/library/daloradius.conf.php
sed -i \"s/DB_PASSWORD.*/DB_PASSWORD', 'radius');/\" /var/www/html/daloradius/library/daloradius.conf.php
sed -i \"s/DB_NAME.*/DB_NAME', 'radius');/\" /var/www/html/daloradius/library/daloradius.conf.php

echo 'Creating FreeRADIUS test user...'
cat <<EOF >> /etc/freeradius/4.0/mods-config/files/authorize
radusr Cleartext-Password := \"radusr\"
EOF

systemctl enable freeradius mariadb apache2
systemctl restart freeradius mariadb apache2
"

# ---- Final Output ----
echo
echo "=== INSTALL COMPLETE ==="
echo "Container ID : $CTID"
echo "Hostname     : $HOSTNAME"
echo
echo "daloRADIUS UI:"
echo "  http://<container-ip>/daloradius/"
echo
echo "daloRADIUS login:"
echo "  administrator / radius"
echo
echo "RADIUS test user:"
echo "  radusr / radusr"
echo
echo "Test RADIUS:"
echo "  pct exec $CTID -- radtest radusr radusr localhost 0 testing123"
