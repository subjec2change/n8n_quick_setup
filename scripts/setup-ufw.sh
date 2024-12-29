#!/bin/bash
# setup-ufw.sh
set -e

echo "Configuring UFW..."
apt install -y ufw
ufw allow OpenSSH
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable
ufw status verbose

echo "UFW configured and enabled."
