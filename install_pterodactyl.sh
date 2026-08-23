#!/bin/bash

set -euo pipefail

# Pterodactyl Panel - Full Auto Installer for Ubuntu
# Usage: curl -fsSL https://raw.githubusercontent.com/.../install.sh | bash

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
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

# Variables - bisa diganti sesuai kebutuhan
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

log_info "=========================================="
log_info "Pterodactyl Panel Auto Installer"
log_info "=========================================="
log_info "Domain: $DOMAIN"
log_info "App URL: $APP_URL"
log_info "=========================================="

# Step 1: Update system
log_info "[1/8] Updating system..."
export DEBIAN_FRONTEND=noninteractive
apt update && apt upgrade -y

# Step 2: Install dependencies
log_info "[2/8] Installing dependencies..."
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
log_info "[3/8] Setting up database..."
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
log_info "[4/8] Downloading Pterodactyl Panel..."
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
log_info "[5/8] Installing composer dependencies..."
cd /var/www/pterodactyl
export COMPOSER_ALLOW_SUPERUSER=1
composer install --no-dev --optimize-autoloader --no-interaction

# Step 6: Setup Environment
log_info "[6/8] Configuring environment..."
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
php artisan p:user:make \
    --no-interaction \
    --email="$ADMIN_EMAIL" \
    --username="$ADMIN_USER" \
    --password="$ADMIN_PASS" \
    --name-first="$ADMIN_FIRST" \
    --name-last="$ADMIN_LAST"

# Setup queue worker
php artisan p:install --no-interaction --force

# Step 7: Configure Nginx
log_info "[7/8] Configuring Nginx..."

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
log_info "[8/8] Setting up cron and queue worker..."

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

# Final info
echo ""
log_info "=========================================="
log_info "INSTALASI SELESAI!"
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
log_info "Simpan kredensial di atas dengan AMAN!"
echo ""
log_info "Langkah selanjutnya:"
log_info "1. Setup SSL dengan Certbot:"
log_info "   apt install certbot python3-certbot-nginx -y"
log_info "   certbot --nginx -d $DOMAIN"
echo ""
log_info "2. Install Wings di node server lain"
echo ""
log_info "3. Login ke panel dan buat node"
echo ""
