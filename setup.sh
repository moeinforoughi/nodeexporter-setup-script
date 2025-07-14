#!/bin/bash

set -e

echo "================= Node Exporter Secure Installer ================="

# Check root privileges
if [[ $EUID -ne 0 ]]; then
    echo "❌ Please run this script as root."
    exit 1
fi

# Ubuntu version check
UBUNTU_VERSION=$(lsb_release -rs)
echo "📦 Detected Ubuntu version: $UBUNTU_VERSION"
case "$UBUNTU_VERSION" in
    18.*|20.*|22.*) echo "✅ Supported Ubuntu version." ;;
    *) echo "⚠️ This Ubuntu version is untested. Proceeding at your own risk." ;;
esac

# Get user input
read -p "🌐 Enter Prometheus Server IP: " PROMETHEUS_IP
read -p "👤 Enter username for Basic Auth (e.g., monitor): " USERNAME
read -s -p "🔒 Enter password for Basic Auth: " PASSWORD
echo

CUSTOM_PORT=9101

echo "📥 Installing required packages (nginx, apache2-utils)..."
apt update -y
apt install -y wget curl nginx apache2-utils

echo "👤 Creating 'node_exporter' user..."
useradd --no-create-home --shell /bin/false node_exporter || true

echo "⬇️ Downloading latest Node Exporter..."
VERSION=$(curl -s https://api.github.com/repos/prometheus/node_exporter/releases/latest | grep tag_name | cut -d '"' -f 4)
URL="https://github.com/prometheus/node_exporter/releases/download/${VERSION}/node_exporter-${VERSION#v}.linux-amd64.tar.gz"
wget -q $URL -O /tmp/node_exporter.tar.gz
tar -xzf /tmp/node_exporter.tar.gz -C /tmp
cp /tmp/node_exporter-*/node_exporter /usr/local/bin/
chown node_exporter:node_exporter /usr/local/bin/node_exporter

echo "🛠️ Creating systemd service for Node Exporter..."
cat <<EOF > /etc/systemd/system/node_exporter.service
[Unit]
Description=Node Exporter
Wants=network-online.target
After=network-online.target

[Service]
User=node_exporter
Group=node_exporter
Type=simple
ExecStart=/usr/local/bin/node_exporter
Restart=always

[Install]
WantedBy=default.target
EOF

systemctl daemon-reexec
systemctl daemon-reload
systemctl enable node_exporter
systemctl restart node_exporter

echo "🔐 Creating Basic Auth credentials..."
htpasswd -cb /etc/nginx/.node_exporter_auth $USERNAME $PASSWORD

echo "🌐 Setting up NGINX reverse proxy with Basic Auth..."
cat <<EOF > /etc/nginx/sites-available/node_exporter
server {
    listen $CUSTOM_PORT;
    server_name _;

    location /metrics {
        proxy_pass http://localhost:9100/metrics;
        auth_basic "Restricted Metrics";
        auth_basic_user_file /etc/nginx/.node_exporter_auth;
        allow $PROMETHEUS_IP;
        deny all;
    }
}
EOF

ln -sf /etc/nginx/sites-available/node_exporter /etc/nginx/sites-enabled/
nginx -t && systemctl restart nginx

# Configure UFW if available
if command -v ufw > /dev/null; then
    echo "🔓 Allowing Prometheus IP through UFW..."
    ufw allow from $PROMETHEUS_IP to any port $CUSTOM_PORT proto tcp || echo "⚠️ UFW not active or failed."
fi

# Get current VM IP
VM_IP=$(hostname -I | awk '{print $1}')

# Check service statuses
echo "✅ Node Exporter service status:"
systemctl is-active --quiet node_exporter && echo "✔️  node_exporter is running." || echo "❌ node_exporter failed."

echo "✅ NGINX service status:"
systemctl is-active --quiet nginx && echo "✔️  nginx is running." || echo "❌ nginx failed."

# Show Prometheus config
echo
echo "✅ Installation completed successfully!"
echo
echo "📋 Add the following job to your Prometheus configuration:"
echo "------------------------------------------------------------"
cat <<EOF

- job_name: 'node_exporter_$VM_IP'
  static_configs:
    - targets: ['$VM_IP:$CUSTOM_PORT']
  metrics_path: /metrics
  basic_auth:
    username: '$USERNAME'
    password: '$PASSWORD'

EOF
echo "------------------------------------------------------------"
