#!/bin/bash
set -e

echo "--- [Part 3/3] Configuring Software and Services ---"

# --- 1. Install Prometheus (On Host) ---
echo "Installing Prometheus on the host..."
wget -qnc https://github.com/prometheus/prometheus/releases/download/v2.54.1/prometheus-2.54.1.linux-amd64.tar.gz
tar xf prometheus-2.54.1.linux-amd64.tar.gz

# Move binaries and config
mv prometheus-2.54.1.linux-amd64/prometheus /usr/local/bin/
mv prometheus-2.54.1.linux-amd64/promtool /usr/local/bin/
mkdir -p /etc/prometheus /var/lib/prometheus
mv prometheus-2.54.1.linux-amd64/consoles /etc/prometheus/
mv prometheus-2.54.1.linux-amd64/console_libraries /etc/prometheus/

# Create user
useradd --no-create-home --shell /bin/false prometheus || echo "User prometheus exists"
chown -R prometheus:prometheus /etc/prometheus /var/lib/prometheus

# Service file
tee /etc/systemd/system/prometheus.service > /dev/null <<EOF
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

# Push snmpd.conf
incus file push - switch/etc/snmp/snmpd.conf <<EOF
agentAddress udp:161
sysLocation "Incus Test Lab"
sysContact Test@example.com
rouser authPrivUser authPriv
EOF

incus exec switch -- systemctl enable --now snmpd

# --- 3. Configure 'AlertManager' Container ---
echo "Configuring AlertManager..."
incus exec alertmanager -- bash -c "apt-get update && apt-get install -y wget"
incus exec alertmanager -- bash -c "wget -qnc https://github.com/prometheus/alertmanager/releases/download/v0.28.1/alertmanager-0.28.1.linux-amd64.tar.gz && tar -xf alertmanager-0.28.1.linux-amd64.tar.gz"
incus exec alertmanager -- mkdir -p /etc/alertmanager

# !!! EDIT CREDENTIALS HERE !!!
echo "Pushing AlertManager Config..."
incus file push - alertmanager/etc/alertmanager/alertmanager.yml <<EOF
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

# AlertManager Service
incus file push - alertmanager/etc/systemd/system/alertmanager.service <<EOF
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
echo "Configuring SNMP Exporter..."
incus exec SNMPExporter -- bash -c "apt-get update && apt-get install -y wget"
incus exec SNMPExporter -- bash -c "wget -qnc https://github.com/prometheus/snmp_exporter/releases/download/v0.29.0/snmp_exporter-0.29.0.linux-amd64.tar.gz && tar xf snmp_exporter-0.29.0.linux-amd64.tar.gz"
incus exec SNMPExporter -- bash -c "cp snmp_exporter-0.29.0.linux-amd64/snmp_exporter /usr/local/bin/ && mkdir -p /etc/snmp_exporter"

# Push snmp.yml (OIDs)
incus file push - SNMPExporter/etc/snmp_exporter/snmp.yml <<EOF
snmpv3_switch:
  walk: [1.3.6.1.2.1.1, 1.3.6.1.2.1.2, 1.3.6.1.2.1.31.1.1]
  metrics:
    - name: sysDescr
      oid: 1.3.6.1.2.1.1.1
      type: DisplayString
      help: "System description"
EOF

# Push auth.yml (Credentials)
incus file push - SNMPExporter/etc/snmp_exporter/auth.yml <<EOF
configs:
  snmpv3_switch:
    version: 3
    username: "authPrivUser"
    security_level: "authPriv"
    auth_protocol: "SHA"
    auth_password: "myAuthPass123"
    priv_protocol: "AES"
    priv_password: "myPrivPass456"
EOF

# SNMP Exporter Service
incus file push - SNMPExporter/etc/systemd/system/snmp_exporter.service <<EOF
[Unit]
Description=Prometheus SNMP Exporter
After=network-online.target

[Service]
User=root
Restart=on-failure
ExecStart=/usr/local/bin/snmp_exporter \\
  --config.file=/etc/snmp_exporter/snmp.yml \\
  --config.auth-file=/etc/snmp_exporter/auth.yml \\
  --web.listen-address=0.0.0.0:9116
[Install]
WantedBy=multi-user.target
EOF

incus exec SNMPExporter -- systemctl daemon-reload
incus exec SNMPExporter -- systemctl enable --now snmp_exporter

# --- 5. Finalize Host Prometheus Config ---
echo "Linking Prometheus to containers..."
tee /etc/prometheus/prometheus.yml > /dev/null <<EOF
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
      target: ["switch.incus"]
    static_configs:
      - targets: ["SNMPExporter.incus:9116"]
EOF

echo "Restarting Host Prometheus..."
systemctl daemon-reload
systemctl restart prometheus

echo "--- Deployment Complete! ---"
echo "Prometheus: http://$(hostname -I | awk '{print $1}'):9090"
