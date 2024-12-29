#!/bin/bash

set -e

# Variables
REPO_URL="https://github.com/DavidMcCauley/n8n_quick_setup.git" # Replace with your actual repo URL
REPO_DIR="n8n_quick_setup"
USER_NAME_PROMPT="Please enter the desired username for n8n setup:"

# Check if running as root
if [ "$EUID" -ne 0 ]; then
  echo "This script requires root privileges. Please run with sudo."
  exit 1
fi

# Function to check for a program
check_program() {
  if ! command -v "$1" &> /dev/null; then
    echo "Installing $1..."
    apt update && apt install -y "$1"
    if ! command -v "$1" &> /dev/null; then
        echo "Error installing $1. Please ensure the package exists and is installed"
        exit 1
    fi
  else
      echo "$1 is already installed."
  fi
}

# Update apt
echo "Updating apt packages..."
apt update

# Check for git
check_program git

# Check if repository already exists
if [ -d "$REPO_DIR" ]; then
  echo "Repository directory $REPO_DIR already exists. Please remove it or choose another location."
  exit 1
fi

# Prompt for username
read -p "$USER_NAME_PROMPT " USERNAME

if [ -z "$USERNAME" ]; then
  echo "Username cannot be empty. Please try again."
  exit 1
fi

# Clone the repository
echo "Cloning repository from $REPO_URL..."
git clone "$REPO_URL"
cd "$REPO_DIR"

# Set execution permissions on the scripts
echo "Setting execute permissions on scripts..."
chmod +x scripts/*.sh

# Perform the setup steps
echo "Running setup scripts..."
./scripts/setup-user.sh "$USERNAME"
./scripts/setup-fail2ban.sh
./scripts/setup-ufw.sh
./scripts/setup-docker.sh "$USERNAME"

echo "Bootstrap process completed."
echo "Navigate to the $REPO_DIR folder to proceed with the next steps in the README."
