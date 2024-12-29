#!/bin/bash

set -e

echo "Installing Fail2Ban..."
apt update && apt install -y fail2ban

cat <<EOF >/etc/fail2ban/jail.local
[DEFAULT]
ignoreip = 127.0.0.1/8
bantime  = 1h
findtime = 10m
maxretry = 5
backend = systemd

[sshd]
enabled = true
port = ssh
logpath = /var/log/auth.log
maxretry = 3
EOF

systemctl restart fail2ban
echo "Fail2Ban installed and basic configuration added."
