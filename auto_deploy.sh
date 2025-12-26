#!/bin/bash
set -e

# --- CHECKS ---
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root (sudo ./auto_deploy.sh)"
  exit
fi

echo "========================================================"
echo "   AUTOMATED LAB DEPLOYMENT (v3.0 - Final Fix)          "
echo "========================================================"

# ========================================================
# [PART 1] DEPENDENCIES & INCUS INSTALLATION
# ========================================================
echo "--- [Part 1] Installing Dependencies and Incus ---"

# 1. Install Dependencies
apt-get update
apt-get install -y spice-vdagent spice-webdavd wget btrfs-progs curl tar

# 2. Add Zabbly Repository
mkdir -p /etc/apt/keyrings
wget -qO - https://pkgs.zabbly.com/key.asc | gpg --dearmor -o /etc/apt/keyrings/zabbly.gpg --yes

cat <<EOF > /etc/apt/sources.list.d/zabbly-incus-stable.sources
Enabled: yes
Types: deb
URIs: https://pkgs.zabbly.com/incus/stable
Suites: $(. /etc/os-release && echo ${VERSION_CODENAME})
Components: main
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/zabbly.gpg
EOF

# 3. Install Incus
apt-get update
apt-get install -y incus

# 4. AUTOMATED INITIALIZATION
echo "--- Automating Incus Initialization ---"
if ! command -v incus &> /dev/null; then
    echo "Incus install failed!"
    exit 1
fi

cat <<EOF | incus admin init --preseed
config: {}
networks:
- config:
    ipv4.address: auto
    ipv6.address: auto
  description: ""
  name: incusbr0
  type: bridge
storage_pools:
- config:
    size: 20GB
  description: ""
  name: default
  driver: btrfs
profiles:
- config: {}
  description: ""
  devices:
    eth0:
      name: eth0
      network: incusbr0
      type: nic
    root:
      path: /
      pool: default
      type: disk
  name: default
cluster: null
EOF

# ========================================================
# [PART 2] DEPLOYING CONTAINERS
# ========================================================
echo "--- [Part 2] Deploying Containers ---"

# 1. Create Containers
incus create images:ubuntu/noble/cloud switch
incus create images:ubuntu/noble/cloud cnt2
incus create images:ubuntu/noble/cloud SNMPExporter
incus create images:ubuntu/noble/cloud alertmanager

# 2. Start Containers
echo "Starting containers..."
incus start switch SNMPExporter alertmanager cnt2

# 3. Wait for Network
echo "Waiting 20s for containers to boot and acquire IP addresses..."
sleep 20
incus list

# ========================================================
# [PART 3] CONFIGURING SOFTWARE AND SERVICES
# ========================================================
echo "--- [Part 3] Configuring Software and Services ---"

# --- 1. Install Prometheus (On Host) ---
echo "Installing Prometheus on the host..."
cd /tmp
wget -qnc https://github.com/prometheus/prometheus/releases/download/v2.54.1/prometheus-2.54.1.linux-amd64.tar.gz
tar xf prometheus-2.54.1.linux-amd64.tar.gz

# Move binaries and config
mv -f prometheus-2.54.1.linux-amd64/prometheus /usr/local/bin/
mv -f prometheus-2.54.1.linux-amd64/promtool /usr/local/bin/
mkdir -p /etc/prometheus /var/lib/prometheus
cp -r prometheus-2.54.1.linux-amd64/consoles /etc/prometheus/
cp -r prometheus-2.54.1.linux-amd64/console_libraries /etc/prometheus/

# Create user
id -u prometheus &>/dev/null || useradd --no-create-home --shell /bin/false prometheus
chown -R prometheus:prometheus /etc/prometheus /var/lib/prometheus

# Service file
cat <<EOF > /etc/systemd/system/prometheus.service
[Unit]
Description=Prometheus Monitoring
After=network.target

[Service]
User=prometheus
Group=prometheus
ExecStart=/usr/local/bin/prometheus \\
        --config.file /etc/prometheus/prometheus.yml \\
        --storage.tsdb.path /var/lib/prometheus/ \\
        --web.console.templates=/etc/prometheus/consoles \\
        --web.console.libraries=/etc/prometheus/console_libraries

[Install]
WantedBy=multi-user.target
EOF

# --- 2. Configure 'switch' Container (SNMPv3 Agent) ---
echo "Configuring SNMPv3 inside 'switch' container..."
incus exec switch -- bash -c "apt-get update && apt-get install -y snmp snmpd snmp-mibs-downloader libsnmp-dev"
incus exec switch -- systemctl stop snmpd
incus exec switch -- net-snmp-config --create-snmpv3-user -ro -a SHA -A myAuthPass123 -x AES -X myPrivPass456 authPrivUser

cat <<EOF | incus file push - switch/etc/snmp/snmpd.conf
agentAddress udp:161
sysLocation "Incus Test Lab"
sysContact Test@example.com
rouser authPrivUser authPriv
EOF

incus exec switch -- systemctl enable --now snmpd

# --- 3. Configure 'AlertManager' Container ---
echo "Configuring AlertManager..."
incus exec alertmanager -- bash -c "apt-get update && apt-get install -y wget curl"
incus exec alertmanager -- bash -c "wget -qnc https://github.com/prometheus/alertmanager/releases/download/v0.28.1/alertmanager-0.28.1.linux-amd64.tar.gz && tar -xf alertmanager-0.28.1.linux-amd64.tar.gz"
incus exec alertmanager -- mkdir -p /etc/alertmanager

# !!! CREDENTIALS HERE !!!
echo "Pushing AlertManager Config..."
cat <<EOF | incus file push - alertmanager/etc/alertmanager/alertmanager.yml
route:
  group_by: ['alertname']
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 5s
  receiver: 'email-notifications'

receivers:
  - name: 'email-notifications'
    email_configs:
      - to: 'YOUR_DESTINATION_EMAIL@gmail.com'
        from: 'YOUR_SENDING_EMAIL@gmail.com'
        smarthost: 'smtp.gmail.com:465'
        auth_username: 'YOUR_SENDING_EMAIL@gmail.com'
        auth_password: 'YOUR-16-DIGIT-APP-PASSWORD'
        auth_identity: 'YOUR_SENDING_EMAIL@gmail.com'
        require_tls: false
EOF

cat <<EOF | incus file push - alertmanager/etc/systemd/system/alertmanager.service
[Unit]
Description=Prometheus Alertmanager
Wants=network-online.target
After=network-online.target

[Service]
User=root
ExecStart=/root/alertmanager-0.28.1.linux-amd64/alertmanager \\
  --config.file=/etc/alertmanager/alertmanager.yml \\
  --cluster.listen-address=""
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

incus exec alertmanager -- systemctl daemon-reload
incus exec alertmanager -- systemctl enable --now alertmanager

# --- 4. Configure 'SNMPExporter' Container ---
echo "Configuring SNMP Exporter (v0.29.0)..."
incus exec SNMPExporter -- bash -c "apt-get update && apt-get install -y wget"
incus exec SNMPExporter -- bash -c "wget -qnc https://github.com/prometheus/snmp_exporter/releases/download/v0.29.0/snmp_exporter-0.29.0.linux-amd64.tar.gz && tar xf snmp_exporter-0.29.0.linux-amd64.tar.gz"
incus exec SNMPExporter -- bash -c "cp snmp_exporter-0.29.0.linux-amd64/snmp_exporter /usr/local/bin/ && mkdir -p /etc/snmp_exporter"

# Push snmp.yml (Updated with CPU support and correct v0.29 syntax)
cat <<EOF | incus file push - SNMPExporter/etc/snmp_exporter/snmp.yml
auths:
  my_switch_auth:
    version: 3
    security_level: authPriv
    username: authPrivUser
    password: myAuthPass123
    auth_protocol: SHA
    priv_protocol: AES
    priv_password: myPrivPass456

modules:
  snmpv3_switch:
    walk: 
      - 1.3.6.1.2.1.1
      - 1.3.6.1.2.1.2
      - 1.3.6.1.2.1.31.1.1
      - 1.3.6.1.4.1.2021
    metrics:
      - name: sysDescr
        oid: 1.3.6.1.2.1.1.1
        type: DisplayString
        help: "System description"
      - name: cpuLoad1Min
        oid: 1.3.6.1.4.1.2021.10.1.3.1
        type: DisplayString
        help: "CPU Load Average (1 min)"
EOF

# Service File
cat <<EOF | incus file push - SNMPExporter/etc/systemd/system/snmp_exporter.service
[Unit]
Description=Prometheus SNMP Exporter
After=network-online.target

[Service]
User=root
Restart=on-failure
ExecStart=/usr/local/bin/snmp_exporter \\
  --config.file=/etc/snmp_exporter/snmp.yml \\
  --web.listen-address=0.0.0.0:9116
[Install]
WantedBy=multi-user.target
EOF

incus exec SNMPExporter -- systemctl daemon-reload
incus exec SNMPExporter -- systemctl enable --now snmp_exporter

# --- 5. Finalize Host Prometheus Config & DNS ---
echo "Fixing Host DNS for Containers..."
# Get container IPs (Fixed: Removed syntax error backslashes)
ALERT_IP=$(incus list alertmanager -c 4 -f csv | cut -d' ' -f1)
SNMP_IP=$(incus list SNMPExporter -c 4 -f csv | cut -d' ' -f1)

# Remove old entries if they exist
sed -i '/alertmanager.incus/d' /etc/hosts
sed -i '/SNMPExporter.incus/d' /etc/hosts

# Add new entries
echo "$ALERT_IP alertmanager.incus" >> /etc/hosts
echo "$SNMP_IP SNMPExporter.incus" >> /etc/hosts

echo "Linking Prometheus to containers..."
cat <<EOF > /etc/prometheus/prometheus.yml
global:
  scrape_interval: 15s

alerting:
  alertmanagers:
  - static_configs:
    - targets: ["alertmanager.incus:9093"]

scrape_configs:
  - job_name: "prometheus"
    static_configs:
      - targets: ["localhost:9090"]

  - job_name: "alertmanager"
    static_configs:
      - targets: ["alertmanager.incus:9093"]

  - job_name: "snmp-exporter"
    metrics_path: /snmp
    params:
      module: [snmpv3_switch]
      auth: [my_switch_auth]
      target: ["switch.incus"]
    static_configs:
      - targets: ["SNMPExporter.incus:9116"]
EOF

echo "Restarting Host Prometheus..."
systemctl daemon-reload
systemctl restart prometheus

echo "========================================================"
echo "          DEPLOYMENT COMPLETE SUCCESSFULLY"
echo "========================================================"
echo "Prometheus: http://$(hostname -I | awk '{print $1}'):9090"
