# Pterodactyl Auto Installer

Script otomatis instalasi Pterodactyl Panel & Wings untuk Ubuntu.

## Quick Start

```bash
curl -fsSL https://raw.githubusercontent.com/VincentSaputra/Pterodactyl-Installer-Vin/main/install.sh | bash
```

Setelah dijalankan, pilih menu:
- `1` - Install Panel Only
- `2` - Install Wings Only
- `3` - Install Panel + Wings

## Non-Interactive Usage

```bash
# Install Panel
curl -fsSL https://raw.githubusercontent.com/VincentSaputra/Pterodactyl-Installer-Vin/main/install.sh | bash -s panel panel.example.com

# Install Wings
curl -fsSL https://raw.githubusercontent.com/VincentSaputra/Pterodactyl-Installer-Vin/main/install.sh | bash -s wings https://panel.example.com
```

## Local Usage

```bash
chmod +x install.sh
./install.sh
./install.sh panel panel.example.com
./install.sh wings https://panel.example.com
```

## Requirements

- Ubuntu 20.04 / 22.04 / 24.04
- Root access
- Domain pointing to server IP (untuk Panel)
- Port 80 & 443 terbuka

## Support

- Repo: https://github.com/VincentSaputra/Pterodactyl-Installer-Vin
