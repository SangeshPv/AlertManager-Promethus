#!/bin/bash
set -e

# --- CHECKS ---
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root (sudo ./auto_deploy.sh)"
  exit
fi

echo "========================================================"
echo "   AUTOMATED LAB DEPLOYMENT "
echo "========================================================"

# ========================================================
# [PART 1] DEPENDENCIES & INCUS INSTALLATION
# ========================================================
echo "--- [Part 1] Installing Dependencies and Incus ---"

# 1. Install Dependencies
apt-get update
# Added jq for processing JSON from incus
apt-get install -y spice-vdagent spice-webdavd wget btrfs-progs curl tar jq

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
# Deployment of the containers
echo "Deploying the containers"
incus create images:ubuntu/noble/cloud switch
incus create images:ubuntu/noble/cloud cnt2
incus create images:ubuntu/noble/cloud SNMPExporter
incus create images:ubuntu/noble/cloud alertmanager
echo "Starting containers..."
incus start switch SNMPExporter alertmanager cnt2

echo "Waiting 20s for containers to boot and acquire IP addresses..."
sleep 20
incus list

# --- Dynamically get container IPs ---
echo "--- Fetching container IP addresses ---"
SWITCH_IP=$(incus list switch --format=json | jq -r '.[0].state.network.eth0.addresses[] | select(.family=="inet").address')
SNMP_EXPORTER_IP=$(incus list SNMPExporter --format=json | jq -r '.[0].state.network.eth0.addresses[] | select(.family=="inet").address')
ALERTMANAGER_IP=$(incus list alertmanager --format=json | jq -r '.[0].state.network.eth0.addresses[] | select(.family=="inet").address')

if [ -z "$SWITCH_IP" ] || [ -z "$SNMP_EXPORTER_IP" ] || [ -z "$ALERTMANAGER_IP" ]; then
    echo "Error: Failed to get IP for one or more containers. Aborting."
    exit 1
fi

echo "  - Switch Target IP: $SWITCH_IP"
echo "  - SNMP Exporter IP: $SNMP_EXPORTER_IP"
echo "  - Alertmanager IP:  $ALERTMANAGER_IP"

# configuring of the containers
echo "Configuring the containers..."
incus exec cnt2 -- bash -s "$SWITCH_IP" "$SNMP_EXPORTER_IP" "$ALERTMANAGER_IP" <<'EOF'
# IPs received as script arguments
TARGET_SWITCH_IP=$1
SNMP_EXPORTER_IP=$2
ALERTMANAGER_IP=$3

## Prometheus Installation on cnt2
echo "Installing Prometheus on cnt2..."
apt-get update
apt-get install -y wget tar nano
wget https://github.com/prometheus/prometheus/releases/download/v2.54.1/prometheus-2.54.1.linux-amd64.tar.gz
tar xvf prometheus-2.54.1.linux-amd64.tar.gz
sleep 10
mv prometheus-2.54.1.linux-amd64/prometheus /usr/local/bin/
mv prometheus-2.54.1.linux-amd64/promtool /usr/local/bin/
rm -rf prometheus-2.54.1.linux-amd64.tar.gz prometheus-2.54.1.linux-amd64
mkdir -p /etc/prometheus /var/lib/prometheus
# Move Configuration Files that might exist in the directory
mv prometheus-2.54.1.linux-amd64/consoles /etc/prometheus/ || true
mv prometheus-2.54.1.linux-amd64/console_libraries /etc/prometheus/ || true

# prometheus.yml Configuration
cat <<EOTEE > /etc/prometheus/prometheus.yml
global:
  scrape_interval: 15s
  evaluation_interval: 15s
  scrape_timeout: 10s

scrape_configs:
  - job_name: 'snmp'
    scrape_interval: 30s
    scrape_timeout: 20s
    metrics_path: /snmp
    params:
      module: [snmpv3_switch]
      auth: [public_v3]
    static_configs:
      - targets:
          - '${TARGET_SWITCH_IP}'
    relabel_configs:
      - source_labels: [__address__]
        target_label: __param_target
      - source_labels: [__param_target]
        target_label: instance
      - target_label: __address__
        replacement: '${SNMP_EXPORTER_IP}:9116'  # SNMP Exporter's IP:port

    metric_relabel_configs:
      - source_labels: [ifIndex]
        regex: '(.*)'
        target_label: interface
      - source_labels: [__name__]
        regex: '^if(HC)?(In|Out)Octets$'
        action: keep

alerting:
  alertmanagers:
    - static_configs:
        - targets:
            - '${ALERTMANAGER_IP}:9093'

rule_files:
  - /etc/prometheus/alerts.yml
EOTEE
#Create a system user and group named prometheus:
useradd --no-create-home --shell /bin/false prometheus
#Set Ownership
chown -R prometheus:prometheus /etc/prometheus /var/lib/prometheus
#Create a systemd Service File
cat <<EOTEE > /etc/systemd/system/prometheus.service
[Unit]
Description=Prometheus Monitoring
After=network.target

[Service]
User=prometheus
Group=prometheus
ExecStart=/usr/local/bin/prometheus \
            --config.file /etc/prometheus/prometheus.yml \
            --storage.tsdb.path /var/lib/prometheus/ \
            --web.console.templates=/etc/prometheus/consoles \
            --web.console.libraries=/etc/prometheus/console_libraries

[Install]
WantedBy=multi-user.target
EOTEE

# Alerts configuration 
cat <<EOTEE > /etc/prometheus/alerts.yml 
groups:
  - name: SNMP Switch Alerts
    rules:
      - alert: SwitchDown
        expr: up{job="snmp"} == 0
        for: 30s
        labels:
          severity: critical
        annotations:
          summary: "SNMP Switch is down"
          description: "The SNMP switch ({{ \$labels.instance }}) is not responding."
EOTEE
systemctl daemon-reload
systemctl start prometheus
systemctl enable prometheus
systemctl status prometheus
EOF

## SNMP Exporter Configuration
echo "Configuring SNMP Exporter..."
incus exec SNMPExporter -- bash <<'EOF'
apt-get update
apt-get install -y curl make nano unzip openssh-server build-essential libsnmp-dev golang-go git snmp snmp-mibs-downloader
systemctl enable --now ssh
wget https://github.com/prometheus/snmp_exporter/releases/download/v0.29.0/snmp_exporter-0.29.0.linux-amd64.tar.gz
tar xvf snmp_exporter-0.29.0.linux-amd64.tar.gz
cp snmp_exporter-0.29.0.linux-amd64/snmp_exporter /usr/local/bin/snmp_exporter
chmod +x /usr/local/bin/snmp_exporter
mkdir -p /etc/snmp_exporter
cd ~
git clone https://github.com/prometheus/snmp_exporter.git
cd ~/snmp_exporter/generator/
rm -f generator.yml
cat <<EOTEE > generator.yml
---
auths:
  public_v3:
    version: 3
    username: Hero
    security_level: authPriv
    auth_protocol: SHA
    password: Hero12345
    priv_protocol: AES
    priv_password: Hero12345

modules:
  snmpv3_switch:
    walk:
      - 1.3.6.1.2.1.1
      - 1.3.6.1.2.1.2
      - 1.3.6.1.2.1.31.1.1
    lookups:
      - source_indexes: [ifIndex]
        lookup: ifDescr
EOTEE
# Generate snmp_exporter.yml
cd ~/snmp_exporter/generator
mkdir -p mibs
curl -L -o mibs/SNMPv2-SMI.txt https://raw.githubusercontent.com/net-snmp/net-snmp/master/mibs/SNMPv2-SMI.txt
curl -L -o mibs/SNMPv2-TC.txt https://raw.githubusercontent.com/net-snmp/net-snmp/master/mibs/SNMPv2-TC.txt
curl -L -o mibs/SNMPv2-MIB.txt https://raw.githubusercontent.com/net-snmp/net-snmp/master/mibs/SNMPv2-MIB.txt
curl -L -o mibs/IF-MIB.txt https://raw.githubusercontent.com/net-snmp/net-snmp/master/mibs/IF-MIB.txt
curl -L -o mibs/IANAifType-MIB.txt https://raw.githubusercontent.com/net-snmp/net-snmp/master/mibs/IANAifType-MIB.txt
go run . generate --no-fail-on-parse-errors
EOF

## SNMPv3 Configuration
echo "Configuring SNMPv3..."
incus exec switch -- bash <<'EOF'
apt-get update
apt-get install -y nano snmp ufw snmpd snmp-mibs-downloader libsnmp-dev
systemctl stop snmpd
# Create SNMPv3 User
net-snmp-create-v3-user -ro -a SHA -A "Hero12345" -x AES -X "Hero12345" Hero
cat <<EOTEE > /etc/snmp/snmpd.conf
rocommunity public
agentAddress udp:161
sysLocation "Incus Test Lab"
sysContact Test@example.com
# SNMPv3 user access
rouser Hero
sysLocation "Incus Test Lab"
EOTEE
systemctl status snmpd
systemctl start snmpd
systemctl enable snmpd 
ufw allow 161/udp
EOF

## ALertmanager Configuration
echo "Configuring Alertmanager..."
incus exec alertmanager -- bash <<'EOF'
apt-get update
apt-get install -y wget tar nano openssh-server
systemctl enable --now ssh

wget https://github.com/prometheus/alertmanager/releases/download/v0.28.1/alertmanager-0.28.1.linux-amd64.tar.gz
tar xvf alertmanager-0.28.1.linux-amd64.tar.gz
cd alertmanager-0.28.1.linux-amd64
mkdir -p /etc/alertmanager
cat <<EOTEE > /etc/alertmanager/alertmanager.yml
route:
  group_by: ['alertname']
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 5s
  receiver: 'email-notifications'  # <- now sends to email by default

receivers:
  - name: 'email-notifications'
    email_configs:
      - to: 'enter email@gmail.com'
        from: 'enter email.mpct@gmail.com'
        smarthost: 'smtp.gmail.com:587'  # or your SMTP server
        auth_username: 'enter email.mpct@gmail.com'
        auth_password: 'generate 1 of your own '
        auth_identity: 'enter email.mpct@gmail.com'
        require_tls: true

  - name: 'web.hook'
    webhook_configs:
      - url: 'http://127.0.0.1:5001/'
        send_resolved: true

inhibit_rules:
  - source_match:
      severity: 'critical'
    target_match:
      severity: 'warning'
    equal: ['alertname', 'dev', 'instance']
EOTEE
#Create a systemd Service File
cat <<EOTEE > /etc/systemd/system/alertmanager.service
[Unit]
Description=Prometheus Alertmanager
Wants=network-online.target
After=network-online.target

[Service]
User=root
Group=root
Type=simple
ExecStart=/root/alertmanager-0.28.1.linux-amd64/alertmanager \
  --config.file=/etc/alertmanager/alertmanager.yml \
  --cluster.listen-address=""
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target

EOTEE
systemctl daemon-reload
systemctl enable alertmanager
systemctl start alertmanager
systemctl status alertmanager
EOF

# Commented out the hardcoded access instruction, as the IP will be dynamic.
# Access the Web UI with http://10.12.242.213:9093
