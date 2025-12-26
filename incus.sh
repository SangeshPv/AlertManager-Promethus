#!/bin/bash
set -e

echo "--- [Part 1/3] Installing Dependencies and Incus ---"

# 1. Install Dependencies
echo "Updating packages..."
apt-get update
apt-get install -y spice-vdagent spice-webdavd wget btrfs-progs curl tar

# 2. Add Zabbly Repository
echo "Adding Zabbly repository..."
wget -O /etc/apt/keyrings/zabbly.asc https://pkgs.zabbly.com/key.asc

cat <<EOF > /etc/apt/sources.list.d/zabbly-incus-stable.sources
Enabled: yes
Types: deb
URIs: https://pkgs.zabbly.com/incus/stable
Suites: $(. /etc/os-release && echo ${VERSION_CODENAME})
Components: main
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/zabbly.asc
EOF

# 3. Install Incus
echo "Installing Incus..."
apt-get update
apt-get install -y incus

echo "--- Part 1 Complete ---"
echo "STOP! You must now manually initialize Incus before running Part 2."
echo "Run this command now:"
echo ""
echo "    sudo incus admin init"
echo ""
echo "Use these answers:"
echo "  - Clustering: no"
echo "  - New storage pool: yes (name: default, driver: btrfs)"
echo "  - Create new BTRFS pool: yes (size: 20GB)"
echo "  - New local network bridge: yes (name: incusbr0)"
echo "  - IPv4/IPv6: auto"
