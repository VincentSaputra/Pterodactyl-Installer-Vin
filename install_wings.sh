#!/bin/bash

set -euo pipefail

# Pterodactyl Wings - Full Auto Installer for Ubuntu
# Usage: curl -fsSL https://raw.githubusercontent.com/.../install_wings.sh | bash

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_step() {
    echo -e "\n${BLUE}==>${NC} $1"
}

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    log_error "Script ini harus dijalankan sebagai root!"
    exit 1
fi

# Check Ubuntu version
if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    if [[ $ID != "ubuntu" ]]; then
        log_error "Script ini hanya untuk Ubuntu!"
        exit 1
    fi
    UBUNTU_VERSION=$VERSION_ID
    log_info "Detected Ubuntu $UBUNTU_VERSION"
else
    log_error "Tidak dapat mendeteksi OS!"
    exit 1
fi

# Check architecture
ARCH=$(uname -m)
if [[ $ARCH != "x86_64" ]]; then
    log_error "Hanya mendukung arsitektur x86_64 (64-bit)!"
    exit 1
fi

# Variables - bisa diganti sesuai kebutuhan
# Configuration from arguments or prompts
if [[ $# -ge 1 ]]; then
    PANEL_URL="$1"
else
    read -p "Masukkan URL Panel (contoh: https://panel.example.com): " PANEL_URL
fi

if [[ -z "$PANEL_URL" ]]; then
    log_error "Panel URL tidak boleh kosong!"
    exit 1
fi

# Remove trailing slash from panel URL
PANEL_URL="${PANEL_URL%/}"

# Wings configuration
WINGS_IP="$(curl -s ifconfig.me || curl -s ipinfo.io/ip || hostname -I | awk '{print $1}')"
WINGS_PORT="8443"
WINGS_TOKEN=""  # Will be set later

log_info "=========================================="
log_info "Pterodactyl Wings Auto Installer"
log_info "=========================================="
log_info "Panel URL: $PANEL_URL"
log_info "Wings IP: $WINGS_IP"
log_info "Wings Port: $WINGS_PORT"
log_info "=========================================="

# Step 1: Update system
log_step "[1/8] Updating system..."
export DEBIAN_FRONTEND=noninteractive
apt update && apt upgrade -y

# Step 2: Install dependencies
log_step "[2/8] Installing dependencies..."
apt install -y \
    curl \
    wget \
    gnupg2 \
    software-properties-common \
    apt-transport-https \
    ca-certificates \
    lsb-release \
    ubuntu-keyring \
    docker.io \
    docker-compose \
    jq \
    unzip \
    git \
    sudo

# Step 3: Configure Docker
log_step "[3/8] Configuring Docker..."
systemctl enable --now docker
systemctl enable --now containerd

# Add current user to docker group
# (we'll use root for everything in this script, but good practice)
usermod -aG docker root || true

# Verify docker installation
if ! command -v docker &> /dev/null; then
    log_error "Docker tidak terinstall dengan benar!"
    exit 1
fi

log_info "Docker version: $(docker --version)"
log_info "Docker Compose version: $(docker-compose --version)"

# Step 4: Download Wings
log_step "[4/8] Downloading Wings..."
mkdir -p /etc/pterodactyl
cd /etc/pterodactyl

# Get latest release
LATEST_URL=$(curl -s https://api.github.com/repos/pterodactyl/wings/releases/latest | grep browser_download_url | grep "linux_amd64.deb" | cut -d '"' -f 4)

if [[ -z "$LATEST_URL" ]]; then
    log_error "Gagal mendapatkan download URL!"
    exit 1
fi

log_info "Downloading: $LATEST_URL"
curl -Lo wings.deb "$LATEST_URL"

# Step 5: Install Wings
log_step "[5/8] Installing Wings..."
apt install -y ./wings.deb || {
    log_error "Gagal install Wings!"
    log_error "Pastikan dependencies terinstall: apt install -y docker.io docker-compose"
    exit 1
}

rm -f wings.deb

# Verify wings installation
if ! command -v wings &> /dev/null; then
    log_error "Wings tidak terinstall dengan benar!"
    exit 1
fi

log_info "Wings installed successfully!"

# Step 6: Configure Wings
log_step "[6/8] Configuring Wings..."

# Get Wings configuration from user
if [[ $# -ge 2 ]]; then
    WINGS_TOKEN="$2"
fi

if [[ -z "$WINGS_TOKEN" ]]; then
    log_warn "Kamu perlu mengambil Wings Token dari Panel!"
    log_info "1. Login ke Panel sebagai Admin"
    log_info "2. Masuk ke Admin Panel -> Nodes -> Create New"
    log_info "3. Isi detail node dan ambil Token"
    log_info "4. Atau buka: $PANEL_URL/admin/nodes"
    echo ""
    read -p "Masukkan Wings Token dari Panel: " WINGS_TOKEN
fi

if [[ -z "$WINGS_TOKEN" ]]; then
    log_error "Wings Token tidak boleh kosong!"
    exit 1
fi

# Create Wings configuration directory
mkdir -p /etc/pterodactyl

# Generate Wings config
log_info "Mengunduh konfigurasi dari Panel..."
CONFIG_RESPONSE=$(curl -s -X POST \
    -H "Authorization: Bearer $WINGS_TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"ip\":\"$WINGS_IP\",\"port\":$WINGS_PORT}" \
    "$PANEL_URL/api/application/nodes/wings" 2>/dev/null || echo "")

# If API doesn't work, create basic config manually
if [[ -z "$CONFIG_RESPONSE" ]] || [[ "$CONFIG_RESPONSE" == *"error"* ]]; then
    log_warn "Tidak dapat mengambil config dari API, membuat config manual..."
    
    # Create basic config file
    cat > /etc/pterodactyl/config.yml <<EOF
# Pterodactyl Wings Configuration
# Generated by auto-installer

remote_query:
  enabled: true
  host: 0.0.0.0
  port: 8080
  ssl:
    enabled: false

  token:
    id: wings
    value: $WINGS_TOKEN

api:
  host: 0.0.0.0
  port: 8443
  ssl:
    enabled: false
    cert: /etc/letsencrypt/live/your-domain/fullchain.pem
    key: /etc/letsencrypt/live/your-domain/privkey.pem

  token:
    id: wings
    value: $WINGS_TOKEN

  remote:
    host: 127.0.0.1
    port: 8080
    token:
      id: wings
      value: $WINGS_TOKEN

system:
  data: /var/lib/pterodactyl
  logs: /var/log/pterodactyl

docker:
  network:
    interface: 172.18.0.1
  storage: /var/lib/pterodactyl

# Server storage allocation
allocation:
  default: 10000

# Network settings
network:
  interfaces:
    eth0:
      ip: $WINGS_IP
      network: eth0
  external:
    interfaces:
      - eth0

# User management
user:
  username: www-data
  group: www-data
EOF
else
    # Try to parse config from API response
    log_info "Menyimpan konfigurasi..."
    echo "$CONFIG_RESPONSE" | jq -r '.config' > /etc/pterodactyl/config.yml 2>/dev/null || {
        log_warn "Gagal parse config dari API, gunakan config manual"
    }
fi

# Set permissions
mkdir -p /var/lib/pterodactyl
mkdir -p /var/log/pterodactyl
mkdir -p /srv/daemon-data
mkdir -p /srv/daemon-value

chown -R www-data:www-data /var/lib/pterodactyl
chown -R www-data:www-data /var/log/pterodactyl
chown -R www-data:www-data /srv/daemon-data
chown -R www-data:www-data /srv/daemon-value

chmod -R 775 /var/lib/pterodactyl
chmod -R 775 /var/log/pterodactyl
chmod -R 775 /srv/daemon-data
chmod -R 775 /srv/daemon-value

# Configure Docker storage
cat > /etc/docker/daemon.json <<EOF
{
  "storage-driver": "overlay2",
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  },
  "userland-proxy-path": "/usr/bin/docker-proxy"
}
EOF

systemctl restart docker

# Step 7: Setup Systemd Service
log_step "[7/8] Setting up systemd service..."

cat > /etc/systemd/system/wings.service <<EOF
[Unit]
Description=Pterodactyl Wings Daemon
After=docker.service
Requires=docker.service

[Service]
User=root
WorkingDirectory=/etc/pterodactyl
LimitNOFILE=4096
PIDFile=/var/run/wings/wings.pid
ExecStartPre=-/usr/bin/mkdir -p /var/run/wings
ExecStart=/usr/bin/wings
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now wings

# Step 8: Firewall Configuration
log_step "[8/8] Configuring firewall..."

# Check if ufw is installed
if command -v ufw &> /dev/null; then
    log_info "Configuring UFW firewall..."
    ufw allow 22/tcp
    ufw allow 80/tcp
    ufw allow 443/tcp
    ufw allow 8443/tcp
    ufw allow 8080/tcp
    ufw allow 2022/tcp
    ufw allow 10000:10100/udp
    ufw --force enable || true
else
    log_warn "UFW tidak terinstall, manual setup firewall diperlukan"
    log_info "Pastikan port berikut terbuka:"
    log_info "  22 (SSH)"
    log_info "  80, 443 (HTTP/HTTPS)"
    log_info "  8080 (Wings Internal)"
    log_info "  8443 (Wings API)"
    log_info "  2022 (SFTP)"
    log_info "  10000-10100/udp (Game servers)"
fi

# Final check
log_step "Checking Wings status..."
sleep 3

if systemctl is-active --quiet wings; then
    log_info "Wings berjalan dengan baik!"
else
    log_error "Wings gagal start! Cek log: journalctl -u wings -n 50"
    systemctl status wings --no-pager
fi

echo ""
log_info "=========================================="
log_info "INSTALASI WINGS SELESAI!"
log_info "=========================================="
echo ""
log_info "Wings IP: $WINGS_IP"
log_info "Wings Port: $WINGS_PORT"
echo ""
log_info "Langkah selanjutnya:"
log_info "1. Login ke Panel: $PANEL_URL/admin/nodes"
log_info "2. Buat Node baru dengan:"
log_info "   - Name: Node 1"
log_info "   - IP: $WINGS_IP"
log_info "   - FQDN: (domain/IP kamu)"
log_info "   - Port: $WINGS_PORT"
log_info "   - SFTP Port: 2022"
log_info "3. Di Node details, klik 'Create Allocation' untuk port game"
log_info "4. Setelah node dibuat, salin Wings Token"
log_info "5. Jalankan script ini lagi dengan token:"
log_info "   ./install_wings.sh $PANEL_URL <TOKEN>"
echo ""
log_info "Atau edit config manual:"
log_info "   nano /etc/pterodactyl/config.yml"
echo ""
log_info "Untuk melihat log:"
log_info "   journalctl -u wings -f"
echo ""
