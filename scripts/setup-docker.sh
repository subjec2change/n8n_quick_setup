#!/bin/bash

set -e

echo "Installing Docker..."
apt update && apt install -y docker.io docker-compose

# Add user to Docker group
USERNAME=$1
if [ -z "$USERNAME" ]; then
  echo "Usage: $0 <username>"
  exit 1
fi

usermod -aG docker $USERNAME
systemctl enable docker

echo "Docker and Docker Compose installed."
