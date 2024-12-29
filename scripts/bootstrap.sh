#!/bin/bash

set -e

# Variables
REPO_URL="https://github.com/DavidMcCauley/n8n_quick_setup.git" # Replace with your actual repo URL
REPO_DIR="n8n_quick_setup"
USER_NAME_PROMPT="Please enter the desired username for n8n setup:"
CURRENT_USER=$(whoami)

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

# Prompt for username
read -p "$USER_NAME_PROMPT " USERNAME

if [ -z "$USERNAME" ]; then
  echo "Username cannot be empty. Please try again."
  exit 1
fi

# Check if the user already exists
if id -u "$USERNAME" &> /dev/null; then
    echo "User $USERNAME already exists."
    read -p "Do you want to continue setup under $USERNAME? (y/N) " CONTINUE
    if [[ "$CONTINUE" != "y" && "$CONTINUE" != "Y" ]]; then
      echo "Aborting setup."
      exit 0
    fi
else
  # Create the new user and add to sudo
  echo "Creating user $USERNAME..."
  adduser "$USERNAME"
  usermod -aG sudo "$USERNAME"
  echo "User $USERNAME created and added to sudo group."
fi


# Check if current user has sudo privileges
if ! sudo -n true 2>/dev/null; then
    echo "Current user does not have sudo privileges."
    if id -u "$USERNAME" &> /dev/null; then
      echo "Attempting to add $USERNAME to the sudo group..."
      usermod -aG sudo "$USERNAME"
    else
        echo "Cannot add to sudo group. Please add the user to the sudo group."
        exit 1
    fi

fi


# Switch to the new user, create the repo directory, pull down the repo, and run the setup scripts
echo "Switching to $USERNAME..."
sudo -u "$USERNAME" bash << EOF
    if [ ! -d "$REPO_DIR" ]; then
      # Clone the repository
      echo "Cloning repository from $REPO_URL..."
      git clone "$REPO_URL"
    else
      echo "Repository directory $REPO_DIR already exists. Please remove it or choose another location."
      exit 1
    fi
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
EOF
