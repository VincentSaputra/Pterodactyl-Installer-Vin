#!/bin/bash

set -euo pipefail

# Pterodactyl Panel & Wings - Full Auto Installer for Ubuntu
# Usage:
#   Panel:  ./install.sh panel <domain>
#   Wings:  ./install.sh wings <panel_url> [token]
#   Help:   ./install.sh --help

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

show_help() {
    echo "Pterodactyl Auto Installer"
    echo ""
    echo "Usage:"
    echo "  ./install.sh panel <domain>       Install Pterodactyl Panel"
    echo "  ./install.sh wings <panel_url>    Install Pterodactyl Wings"
    echo "  ./install.sh wings <panel_url> <token>  Install Wings with token"
    echo ""
    echo "Examples:"
    echo "  ./install.sh panel panel.example.com"
    echo "  ./install.sh wings https://panel.example.com"
    echo "  ./install.sh wings https://panel.example.com abc123token"
    echo ""
    exit 0
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
else
    log_error "Tidak dapat mendeteksi OS!"
    exit 1
fi

# Show help
if [[ "${1:-}" == "--help" ]] || [[ "${1:-}" == "-h" ]]; then
    show_help
fi

# ============================================================
# PANEL INSTALLER
# ============================================================
install_panel() {
    log_info "=========================================="
    log_info "Pterodactyl Panel Auto Installer"
    log_info "=========================================="

    DOMAIN="${1:-panel.example.com}"
    DB_NAME="panel"
    DB_USER="pterodactyl"
    DB_PASS="$(openssl rand -base64 32)"
    APP_NAME="Pterodactyl"
    APP_URL="https://${DOMAIN}"
    ADMIN_EMAIL="admin@example.com"
    ADMIN_USER="admin"
    ADMIN_PASS="$(openssl rand -base64 16)"
    ADMIN_FIRST="Admin"
    ADMIN_LAST="User"

    log_info "Domain: $DOMAIN"
    log_info "App URL: $APP_URL"
    log_info "=========================================="

    # Step 1: Update system
    log_step "[1/8] Updating system..."
    export DEBIAN_FRONTEND=noninteractive
    apt update && apt upgrade -y

    # Step 2: Install dependencies
    log_step "[2/8] Installing dependencies..."
    apt install -y \
        nginx \
        mysql-server \
        php8.3 \
        php8.3-{common,cli,gd,mysql,mbstring,bcmath,xml,fpm,curl,zip} \
        composer \
        unzip \
        git \
        redis-server \
        curl \
        wget \
        jq \
        software-properties-common

    # Install PHP 8.3 if not available
    if ! dpkg -l | grep -q php8.3; then
        log_warn "PHP 8.3 not found, installing from PPA..."
        add-apt-repository ppa:ondrej/php -y
        apt update
        apt install -y php8.3 php8.3-{common,cli,gd,mysql,mbstring,bcmath,xml,fpm,curl,zip}
    fi

    # Start services
    systemctl enable --now mysql
    systemctl enable --now redis-server
    systemctl enable --now nginx
    systemctl enable --now php8.3-fpm

    # Step 3: Setup Database
    log_step "[3/8] Setting up database..."
    mysql -u root <<EOF
CREATE DATABASE IF NOT EXISTS ${DB_NAME};
CREATE USER IF NOT EXISTS '${DB_USER}'@'127.0.0.1' IDENTIFIED BY '${DB_PASS}';
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'127.0.0.1';
GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
EOF

    log_info "Database created: $DB_NAME"
    log_info "Database user: $DB_USER"
    log_info "Database pass: $DB_PASS"

    # Step 4: Download Pterodactyl
    log_step "[4/8] Downloading Pterodactyl Panel..."
    mkdir -p /var/www/pterodactyl
    cd /var/www/pterodactyl

    # Get latest release
    LATEST_URL=$(curl -s https://api.github.com/repos/pterodactyl/panel/releases/latest | grep browser_download_url | grep panel.tar.gz | cut -d '"' -f 4)

    if [[ -z "$LATEST_URL" ]]; then
        log_error "Gagal mendapatkan download URL!"
        exit 1
    fi

    curl -Lo panel.tar.gz "$LATEST_URL"
    tar -xzvf panel.tar.gz
    rm panel.tar.gz

    chown -R www-data:www-data /var/www/pterodactyl/*

    # Step 5: Install Composer Dependencies
    log_step "[5/8] Installing composer dependencies..."
    cd /var/www/pterodactyl
    export COMPOSER_ALLOW_SUPERUSER=1
    composer install --no-dev --optimize-autoloader --no-interaction

    # Step 6: Setup Environment
    log_step "[6/8] Configuring environment..."
    cp .env.example .env

    php artisan key:generate --force

    # Update .env file
    sed -i "s|APP_NAME=.*|APP_NAME=\"${APP_NAME}\"|g" .env
    sed -i "s|APP_ENV=.*|APP_ENV=production|g" .env
    sed -i "s|APP_DEBUG=.*|APP_DEBUG=false|g" .env
    sed -i "s|APP_URL=.*|APP_URL=${APP_URL}|g" .env
    sed -i "s|DB_HOST=.*|DB_HOST=127.0.0.1|g" .env
    sed -i "s|DB_PORT=.*|DB_PORT=3306|g" .env
    sed -i "s|DB_DATABASE=.*|DB_DATABASE=${DB_NAME}|g" .env
    sed -i "s|DB_USERNAME=.*|DB_USERNAME=${DB_USER}|g" .env
    sed -i "s|DB_PASSWORD=.*|DB_PASSWORD=${DB_PASS}|g" .env
    sed -i "s|REDIS_HOST=.*|REDIS_HOST=127.0.0.1|g" .env
    sed -i "s|MAIL_DRIVER=.*|MAIL_DRIVER=smtp|g" .env

    # Run migrations and seed
    php artisan migrate --seed --force

    # Create admin user
    if [[ -t 0 ]]; then
        log_info "Membuat admin user..."
        read -p "Email admin: " ADMIN_EMAIL
        read -p "Username admin: " ADMIN_USER
        read -sp "Password admin: " ADMIN_PASS
        echo ""
        read -p "Nama depan: " ADMIN_FIRST
        read -p "Nama belakang: " ADMIN_LAST
    else
        ADMIN_EMAIL="${ADMIN_EMAIL:-admin@example.com}"
        ADMIN_USER="${ADMIN_USER:-admin}"
        ADMIN_PASS="${ADMIN_PASS:-$(openssl rand -base64 16)}"
        ADMIN_FIRST="${ADMIN_FIRST:-Admin}"
        ADMIN_LAST="${ADMIN_LAST:-User}"
        log_info "Membuat admin user dengan kredensial default..."
    fi

    php artisan p:user:make \
        --no-interaction \
        --email="$ADMIN_EMAIL" \
        --username="$ADMIN_USER" \
        --password="$ADMIN_PASS" \
        --name-first="$ADMIN_FIRST" \
        --name-last="$ADMIN_LAST"

    # Step 7: Configure Nginx
    log_step "[7/8] Configuring Nginx..."

    cat > /etc/nginx/sites-available/pterodactyl.conf <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};
    root /var/www/pterodactyl/public;
    index index.php;

    client_max_body_size 100m;
    client_body_timeout 60s;

    add_header X-Frame-Options "SAMEORIGIN";
    add_header X-XSS-Protection "1; mode=block";
    add_header X-Content-Type-Options "nosniff";

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php$ {
        fastcgi_pass unix:/var/run/php/php8.3-fpm.sock;
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$realpath_root\$fastcgi_script_name;
        fastcgi_param DOCUMENT_ROOT \$realpath_root;
        internal;
    }

    location ~ /\.ht {
        deny all;
    }
}
EOF

    # Enable site
    ln -sf /etc/nginx/sites-available/pterodactyl.conf /etc/nginx/sites-enabled/
    rm -f /etc/nginx/sites-enabled/default

    # Test and reload nginx
    nginx -t && systemctl reload nginx

    # Step 8: Setup Cron & Queue Worker
    log_step "[8/8] Setting up cron and queue worker..."

    # Cron
    (crontab -l 2>/dev/null; echo "* * * * * php /var/www/pterodactyl/artisan schedule:run --no-interaction") | crontab -

    # Queue worker
    cat > /etc/systemd/system/pteroq.service <<EOF
[Unit]
Description=Pterodactyl Queue Worker
After=redis-server.service mysql.service

[Service]
User=www-data
Group=www-data
Restart=always
ExecStart=/usr/bin/php /var/www/pterodactyl/artisan queue:work --queue=high,standard,low --sleep=3 --tries=3
StartLimitInterval=180
StartLimitBurst=30

[Install]
WantedBy=multi-user.target
EOF

    systemctl enable --now pteroq.service

    # Set permissions
    chown -R www-data:www-data /var/www/pterodactyl/*

    # Save credentials to file
    cat > /root/pterodactyl_credentials.txt <<EOF
==========================================
PTERODACTYL PANEL - KREDENSIAL
==========================================

Panel URL: $APP_URL
Admin Email: $ADMIN_EMAIL
Admin User: $ADMIN_USER
Admin Pass: $ADMIN_PASS

Database: $DB_NAME
DB User: $DB_USER
DB Pass: $DB_PASS

==========================================
Dibuat: $(date)
==========================================
EOF

    chmod 600 /root/pterodactyl_credentials.txt

    # Final info
    echo ""
    log_info "=========================================="
    log_info "INSTALASI PANEL SELESAI!"
    log_info "=========================================="
    echo ""
    log_info "Panel URL: $APP_URL"
    log_info "Admin Email: $ADMIN_EMAIL"
    log_info "Admin User: $ADMIN_USER"
    log_info "Admin Pass: $ADMIN_PASS"
    echo ""
    log_info "Database: $DB_NAME"
    log_info "DB User: $DB_USER"
    log_info "DB Pass: $DB_PASS"
    echo ""
    log_info "Kredensial disimpan di: /root/pterodactyl_credentials.txt"
    log_info "Simpan kredensial di atas dengan AMAN!"
    echo ""
    log_info "Langkah selanjutnya:"
    log_info "1. Setup SSL dengan Certbot:"
    log_info "   apt install certbot python3-certbot-nginx -y"
    log_info "   certbot --nginx -d $DOMAIN"
    echo ""
    log_info "2. Install Wings di node server lain dengan:"
    log_info "   ./install.sh wings $APP_URL"
    echo ""
    log_info "3. Login ke panel dan buat node"
    echo ""
}

# ============================================================
# WINGS INSTALLER
# ============================================================
install_wings() {
    PANEL_URL="${1:-}"
    WINGS_TOKEN="${2:-}"

    # Remove trailing slash from panel URL
    PANEL_URL="${PANEL_URL%/}"

    if [[ -z "$PANEL_URL" ]]; then
        log_error "Panel URL tidak boleh kosong!"
        echo "Usage: ./install.sh wings <panel_url> [token]"
        exit 1
    fi

    WINGS_IP="$(curl -s ifconfig.me || curl -s ipinfo.io/ip || hostname -I | awk '{print $1}')"
    WINGS_PORT="8443"

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

    usermod -aG docker root || true

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

    if ! command -v wings &> /dev/null; then
        log_error "Wings tidak terinstall dengan benar!"
        exit 1
    fi

    log_info "Wings installed successfully!"

    # Step 6: Configure Wings
    log_step "[6/8] Configuring Wings..."

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

    mkdir -p /etc/pterodactyl

    log_info "Mengunduh konfigurasi dari Panel..."
    CONFIG_RESPONSE=$(curl -s -X POST \
        -H "Authorization: Bearer $WINGS_TOKEN" \
        -H "Content-Type: application/json" \
        -d "{\"ip\":\"$WINGS_IP\",\"port\":$WINGS_PORT}" \
        "$PANEL_URL/api/application/nodes/wings" 2>/dev/null || echo "")

    if [[ -z "$CONFIG_RESPONSE" ]] || [[ "$CONFIG_RESPONSE" == *"error"* ]]; then
        log_warn "Tidak dapat mengambil config dari API, membuat config manual..."
        
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

allocation:
  default: 10000

network:
  interfaces:
    eth0:
      ip: $WINGS_IP
      network: eth0
  external:
    interfaces:
      - eth0

user:
  username: www-data
  group: www-data
EOF
    else
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
    echo ""
    log_info "Atau edit config manual:"
    log_info "   nano /etc/pterodactyl/config.yml"
    echo ""
    log_info "Untuk melihat log:"
    log_info "   journalctl -u wings -f"
    echo ""
}

# ============================================================
# MAIN ROUTER
# ============================================================
MODE="${1:-}"

# Non-interactive mode (via arguments)
if [[ "$MODE" == "panel" ]]; then
    shift
    install_panel "$@"
    exit 0
elif [[ "$MODE" == "wings" ]]; then
    shift
    install_wings "$@"
    exit 0
fi

# If running via pipe (curl | bash) without args, stdin is not a terminal
# The script needs interactive input, so we must re-execute it properly
if [[ ! -t 0 ]]; then
    echo "=========================================="
    echo "  Pterodactyl Auto Installer"
    echo "=========================================="
    echo ""
    echo "Script ini memerlukan input interaktif."
    echo "Jalankan dengan salah satu cara:"
    echo ""
    echo "  1) bash <(curl -s https://raw.githubusercontent.com/VincentSaputra/Pterodactyl-Installer-Vin/main/install.sh)"
    echo "  2) curl -s URL -o install.sh && bash install.sh"
    echo "  3) curl -s URL | bash -s panel panel.example.com"
    echo ""
    exit 1
fi

# Interactive menu mode
echo ""
echo "=========================================="
echo "  Pterodactyl Auto Installer"
echo "=========================================="
echo ""
echo "Pilih instalasi:"
echo "  1) Panel Only"
echo "  2) Wings Only"
echo "  3) Panel + Wings"
echo ""
read -p "Masukkan pilihan [1-3]: " choice

case "$choice" in
    1)
        read -p "Masukkan domain Panel (contoh: panel.example.com): " DOMAIN
        if [[ -z "$DOMAIN" ]]; then
            log_error "Domain tidak boleh kosong!"
            exit 1
        fi
        install_panel "$DOMAIN"
        ;;
    2)
        read -p "Masukkan URL Panel (contoh: https://panel.example.com): " PANEL_URL
        if [[ -z "$PANEL_URL" ]]; then
            log_error "Panel URL tidak boleh kosong!"
            exit 1
        fi
        install_wings "$PANEL_URL"
        ;;
    3)
        read -p "Masukkan domain Panel (contoh: panel.example.com): " DOMAIN
        if [[ -z "$DOMAIN" ]]; then
            log_error "Domain tidak boleh kosong!"
            exit 1
        fi
        install_panel "$DOMAIN"
        echo ""
        log_info "Panel selesai! Sekarang install Wings..."
        read -p "Masukkan URL Panel (contoh: https://panel.example.com): " PANEL_URL
        if [[ -z "$PANEL_URL" ]]; then
            log_error "Panel URL tidak boleh kosong!"
            exit 1
        fi
        install_wings "$PANEL_URL"
        ;;
    *)
        log_error "Pilihan tidak valid!"
        exit 1
        ;;
esac
