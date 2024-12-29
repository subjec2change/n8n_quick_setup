#!/bin/bash

set -e

USERNAME=$1
SSH_PORT=${2:-22}

if [ -z "$USERNAME" ]; then
  echo "Usage: $0 <username> [ssh-port]"
  exit 1
fi

# Create a new user
adduser $USERNAME
usermod -aG sudo $USERNAME

# Setup SSH key-based authentication
mkdir -p /home/$USERNAME/.ssh
chmod 700 /home/$USERNAME/.ssh
cp ~/.ssh/authorized_keys /home/$USERNAME/.ssh/authorized_keys
chown -R $USERNAME:$USERNAME /home/$USERNAME/.ssh

# Secure SSH
sed -i "s/#Port 22/Port $SSH_PORT/" /etc/ssh/sshd_config
sed -i "s/PermitRootLogin yes/PermitRootLogin no/" /etc/ssh/sshd_config
sed -i "s/#PasswordAuthentication yes/PasswordAuthentication no/" /etc/ssh/sshd_config
systemctl restart ssh

echo "User $USERNAME created and SSH configured on port $SSH_PORT."
