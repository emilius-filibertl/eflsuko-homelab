#!/bin/bash
# Post-installation script for new Debian LXCs on Proxmox
#
# Usage:
#   bash post-install.sh              # base setup + Docker
#   bash post-install.sh --no-docker  # base setup only (e.g. Postgres LXC)
#
# For Docker: enable Options -> Features -> nesting=1 (and keyctl=1 if
# unprivileged) on the LXC in Proxmox BEFORE running this script.

set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
TIMEZONE="Asia/Jakarta"
INSTALL_DOCKER=true

if [[ "${1:-}" == "--no-docker" ]]; then
    INSTALL_DOCKER=false
fi

if [[ $EUID -ne 0 ]]; then
    echo "Run this script as root."
    exit 1
fi

echo "==> Updating system..."
apt-get update
apt-get -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" upgrade

echo "==> Installing base packages..."
apt-get install -y \
    ca-certificates \
    curl \
    wget \
    git \
    nano \
    unattended-upgrades

echo "==> Setting timezone to ${TIMEZONE}..."
if ! timedatectl set-timezone "$TIMEZONE" 2>/dev/null; then
    ln -sf "/usr/share/zoneinfo/${TIMEZONE}" /etc/localtime
    echo "$TIMEZONE" > /etc/timezone
fi

echo "==> Enabling unattended security upgrades..."
echo "unattended-upgrades unattended-upgrades/enable_auto_updates boolean true" \
    | debconf-set-selections
dpkg-reconfigure -f noninteractive unattended-upgrades

if [[ "$INSTALL_DOCKER" == true ]]; then
    echo "==> Checking LXC nesting support..."
    if [[ ! -w /sys/fs/cgroup ]] && ! grep -q nesting /proc/self/mountinfo 2>/dev/null; then
        echo "WARNING: nesting may not be enabled for this LXC."
        echo "         If Docker fails to start, enable Options -> Features -> nesting in Proxmox."
    fi

    echo "==> Removing conflicting Docker packages..."
    for pkg in docker.io docker-compose docker-doc podman-docker containerd runc; do
        apt-get remove -y "$pkg" 2>/dev/null || true
    done

    echo "==> Configuring Docker repository..."
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc

    cat > /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: $(. /etc/os-release && echo "$VERSION_CODENAME")
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF

    echo "==> Installing Docker..."
    apt-get update
    apt-get install -y \
        docker-ce \
        docker-ce-cli \
        containerd.io \
        docker-buildx-plugin \
        docker-compose-plugin

    echo "==> Configuring Docker log rotation..."
    mkdir -p /etc/docker
    cat > /etc/docker/daemon.json <<EOF
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
EOF

    echo "==> Enabling Docker..."
    systemctl enable docker
    systemctl restart docker

    echo "==> Verifying Docker..."
    docker --version
    docker compose version
    docker run --rm hello-world
    docker image rm hello-world >/dev/null
fi

echo "==> Cleaning up..."
apt-get autoremove -y
apt-get clean

echo "==> Post installation completed successfully."