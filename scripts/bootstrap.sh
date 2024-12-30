#!/bin/bash

set -e

###############################################################################
# n8n Quick Setup Bootstrap Script
# Version: 0.051
###############################################################################

# --- GLOBAL CONFIG & ENVIRONMENT ---
export DEBIAN_FRONTEND=noninteractive

SCRIPT_VERSION="0.051"
REPO_URL="https://github.com/DavidMcCauley/n8n_quick_setup.git"
REPO_DIR="n8n_quick_setup"
USER_NAME_PROMPT="Please enter the desired username for n8n setup:"
VIM_COLORSCHEME="desert"

# --- HELPER FUNCTIONS ---

check_program() {
  # Installs a given package if it's not already installed
  if ! command -v "$1" &> /dev/null; then
    echo "Installing $1..."
    apt update && apt install -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" -y "$1"
    if ! command -v "$1" &> /dev/null; then
      echo "Error installing $1. Please ensure the package exists and is installed"
      exit 1
    fi
  else
    echo "$1 is already installed."
  fi
}

verify_command() {
  if [ "$1" -ne 0 ]; then
    echo "Verification failed. Aborting the script at stage: $2"
    exit 1
  else
    echo "Verification passed for: $2"
  fi
}

# --- CHECK IF RUNNING AS ROOT OR SUDO ---
if [ "$EUID" -ne 0 ]; then
  if ! sudo -n true 2>/dev/null; then
    echo "This script requires root or sudo privileges. Please run with sudo."
    exit 1
  else
    echo "Running as non-root user with sudo privileges..."
    IS_ROOT=false
  fi
else
  echo "Running as root user..."
  IS_ROOT=true
fi

echo "n8n Quick Setup Bootstrap.sh version: v$SCRIPT_VERSION"

###############################################################################
# STAGE 1: System Preparation
###############################################################################
echo ""
echo "--- STAGE 1: System Preparation ---"

echo "Updating and Upgrading apt packages..."
apt update
UPDATES=$(apt list --upgradable 2>/dev/null | wc -l)
apt upgrade -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" -y
verify_command $? "apt update && apt upgrade -y"

echo "Removing unnecessary packages..."
apt autoremove -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" -y
verify_command $? "apt autoremove -y"

check_program git
verify_command $? "git install check"

check_program vim
verify_command $? "vim install check"

# Determine if any upgrades actually happened:
if [ "$UPDATES" -gt 1 ]; then
  UPDATES_APPLIED=true
else
  UPDATES_APPLIED=false
fi

# Check if a reboot is required
REBOOT_REQUIRED=$(ls /var/run/reboot-required 2>/dev/null || true)
if [ -n "$REBOOT_REQUIRED" ] && $UPDATES_APPLIED; then
  echo "--- STAGE 1 Requires Reboot ---"
  echo "A system reboot is required to complete updates."
  if [ "$IS_ROOT" = true ]; then
    REBOOT_CMD="./bootstrap.sh"
  else
    REBOOT_CMD="sudo ./bootstrap.sh"
  fi
  echo "After the reboot, please run the script again using this command: $REBOOT_CMD"
  echo "Rebooting in 5 seconds..."
  sleep 5
  sudo reboot
fi

if $UPDATES_APPLIED; then
  echo "--- STAGE 1 Completed With Changes ---"
  echo "Updates were applied to the system."
else
  echo "--- STAGE 1 Completed Without Changes ---"
  echo "No updates were applied to the system."
fi

###############################################################################
# STAGE 2: User Setup
###############################################################################
echo ""
echo "--- STAGE 2: User Setup ---"

read -p "$USER_NAME_PROMPT " USERNAME
if [ -z "$USERNAME" ]; then
  echo "Username cannot be empty. Please try again."
  exit 1
fi

if id -u "$USERNAME" &>/dev/null; then
  echo "User $USERNAME already exists."
  read -p "Do you want to continue setup under $USERNAME? (y/N) " CONTINUE
  if [[ "$CONTINUE" != "y" && "$CONTINUE" != "Y" ]]; then
    echo "Aborting setup."
    exit 0
  fi
else
  if $IS_ROOT; then
    echo "Creating user $USERNAME..."
    adduser "$USERNAME"
    usermod -aG sudo "$USERNAME"
    echo "User $USERNAME created and added to sudo group."
  else
    echo "You must create $USERNAME user for the setup. Please run the script as root."
    exit 1
  fi
fi

# Ensure the user’s home dir is at least drwx--x--x (711) so the user can traverse
chmod 711 /home/"$USERNAME"

# Confirm current user has sudo privileges
if ! sudo -n true 2>/dev/null; then
  echo "Current user does not have sudo privileges."
  if id -u "$USERNAME" &>/dev/null; then
    echo "Attempting to add $USERNAME to the sudo group..."
    usermod -aG sudo "$USERNAME"
    verify_command $? "Adding user to sudo"
  else
    echo "Cannot add to sudo group. Please add the user to the sudo group manually."
    exit 1
  fi
fi

# Set default vim colorscheme
echo "Setting default vim colorscheme to '$VIM_COLORSCHEME' for all users..."
echo "set background=dark
colorscheme $VIM_COLORSCHEME
" | sudo tee /etc/vim/vimrc.local
verify_command $? "Setting default vim colorscheme for all users"

# Set vim colorscheme for $USERNAME
echo "Setting vim colorscheme to '$VIM_COLORSCHEME' for user '$USERNAME'..."
echo "colorscheme $VIM_COLORSCHEME" | sudo -u "$USERNAME" tee /home/"$USERNAME"/.vimrc
verify_command $? "Setting vim colorscheme for user '$USERNAME'"

read -n 1 -s -r -p "Press any key to continue to Stage 3..."

###############################################################################
# STAGE 3: Clone the Repository
###############################################################################
echo ""
echo "--- STAGE 3: Clone the Repository ---"

if [ -d "/home/$USERNAME/$REPO_DIR" ]; then
  echo "Repository directory /home/$USERNAME/$REPO_DIR already exists."
  echo "Setting $USERNAME as owner of this directory"
  sudo chown -R "$USERNAME":"$USERNAME" "/home/$USERNAME/$REPO_DIR"
  verify_command $? "Ownership transfer complete"
else
  echo "Cloning repository from $REPO_URL to /home/$USERNAME..."
  sudo -u "$USERNAME" mkdir -p "/home/$USERNAME"
  sudo -u "$USERNAME" git clone "$REPO_URL" "/home/$USERNAME/$REPO_DIR"
  verify_command $? "Clone repository"
fi

# Also ensure the n8n_quick_setup folder is fully accessible to the user
sudo chmod -R u+rwx "/home/$USERNAME/$REPO_DIR"

echo "--- STAGE 3 Completed Successfully ---"
read -n 1 -s -r -p "Press any key to continue to Stage 4..."

###############################################################################
# STAGE 4: Configure and Deploy
###############################################################################
echo ""
echo "--- STAGE 4: Configure and Deploy ---"
echo "Switching to $USERNAME and completing remaining setup..."

sudo -u "$USERNAME" bash << 'EOF'
set -e

# Re-declare verify_command inside the subshell:
verify_command() {
  if [ "$1" -ne 0 ]; then
    echo "Verification failed. Aborting the script at stage: $2"
    exit 1
  else
    echo "Verification passed for: $2"
  fi
}

echo "Moving into n8n_quick_setup..."
cd "n8n_quick_setup"

echo "Setting execute permissions on scripts..."
chmod +x scripts/*.sh
verify_command $? "Setting permissions"

echo "Running setup scripts..."
./scripts/setup-user.sh "$USER"
verify_command $? "Running setup-user.sh"

./scripts/setup-fail2ban.sh
verify_command $? "Running setup-fail2ban.sh"

./scripts/setup-ufw.sh
verify_command $? "Running setup-ufw.sh"

./scripts/setup-docker.sh "$USER"
verify_command $? "Running setup-docker.sh"

echo "Bootstrap process completed."
echo "Navigate to the n8n_quick_setup folder to proceed with the next steps in the README."
EOF

echo "--- STAGE 4 Completed Successfully ---"
echo "All stages completed!"
