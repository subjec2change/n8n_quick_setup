#!/bin/bash

set -e

###############################################################################
# n8n Quick Setup Bootstrap Script with Pre-Run Checks & Rerun Logic
# Version: 0.052
###############################################################################

# --- GLOBAL CONFIG & ENVIRONMENT ---
export DEBIAN_FRONTEND=noninteractive

SCRIPT_VERSION="0.052"
REPO_URL="https://github.com/DavidMcCauley/n8n_quick_setup.git"
REPO_DIR="n8n_quick_setup"
USER_NAME_PROMPT="Please enter the desired username for n8n setup:"
VIM_COLORSCHEME="desert"
STATUS_FILE="/tmp/n8n_bootstrap_status"
# The STATUS_FILE holds simple lines like STAGE_1_COMPLETED, STAGE_2_COMPLETED, etc.

###############################################################################
# HELPER FUNCTIONS
###############################################################################

log() { echo -e "[LOG] $*"; }
err() { echo -e "[ERR] $*" >&2; }

check_program() {
  # Installs a given package if not already installed
  if ! command -v "$1" &>/dev/null; then
    log "Installing $1..."
    apt update && apt install -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" "$1"
    if ! command -v "$1" &>/dev/null; then
      err "Error installing $1. Please ensure the package exists and is installed"
      exit 1
    fi
  else
    log "$1 is already installed."
  fi
}

verify_command() {
  if [ "$1" -ne 0 ]; then
    err "Verification failed. Aborting the script at stage: $2"
    exit 1
  else
    log "Verification passed for: $2"
  fi
}

# Writes a marker to the status file
mark_stage_completed() {  
  echo "$1" >> "$STATUS_FILE"
}

# Checks if a stage was previously completed
is_stage_completed() {  
  grep -qx "$1" "$STATUS_FILE" 2>/dev/null
}

###############################################################################
# CHECK IF RUNNING AS ROOT OR SUDO
###############################################################################
if [ "$EUID" -ne 0 ]; then
  if ! sudo -n true 2>/dev/null; then
    err "This script requires root or sudo privileges. Please run with sudo."
    exit 1
  else
    log "Running as non-root user with sudo privileges..."
    IS_ROOT=false
  fi
else
  log "Running as root user..."
  IS_ROOT=true
fi

log "n8n Quick Setup Bootstrap.sh version: v$SCRIPT_VERSION"

###############################################################################
# ENVIRONMENT PRE-CHECK: Gather Info About the System
###############################################################################
# Example: log some environment details
OS_NAME="$(. /etc/os-release; echo "$NAME")"
OS_VERSION="$(. /etc/os-release; echo "$VERSION")"
HOSTNAME_INFO="$(hostname)"
log "Environment Info:"
log "  OS: $OS_NAME $OS_VERSION"
log "  Hostname: $HOSTNAME_INFO"
log "  Current UID: $EUID (root? $IS_ROOT)"

# Ensure the status file exists
touch "$STATUS_FILE"

###############################################################################
# STAGE 1: System Preparation
###############################################################################
log ""
log "--- STAGE 1: System Preparation ---"

if is_stage_completed "STAGE_1_COMPLETED"; then
  log "Stage 1 was previously completed. Skipping..."
else
  log "Updating and Upgrading apt packages..."
  apt update
  UPDATES=$(apt list --upgradable 2>/dev/null | wc -l)
  apt upgrade -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold"
  verify_command $? "apt update && apt upgrade -y"

  log "Removing unnecessary packages..."
  apt autoremove -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold"
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
  REBOOT_REQUIRED="$(ls /var/run/reboot-required 2>/dev/null || true)"
  if [ -n "$REBOOT_REQUIRED" ] && $UPDATES_APPLIED; then
    log "--- STAGE 1 Requires Reboot ---"
    log "A system reboot is required to complete updates."
    if [ "$IS_ROOT" = true ]; then
      REBOOT_CMD="./bootstrap.sh"
    else
      REBOOT_CMD="sudo ./bootstrap.sh"
    fi
    log "After the reboot, please run the script again using: $REBOOT_CMD"
    log "Rebooting in 5 seconds..."
    sleep 5
    sudo reboot
  fi

  if $UPDATES_APPLIED; then
    log "--- STAGE 1 Completed With Changes ---"
  else
    log "--- STAGE 1 Completed Without Changes ---"
  fi

  # Mark stage completed
  mark_stage_completed "STAGE_1_COMPLETED"
fi

###############################################################################
# STAGE 2: User Setup
###############################################################################
log ""
log "--- STAGE 2: User Setup ---"

if is_stage_completed "STAGE_2_COMPLETED"; then
  log "Stage 2 was previously completed. Skipping..."
else
  read -p "$USER_NAME_PROMPT " USERNAME
  if [ -z "$USERNAME" ]; then
    err "Username cannot be empty. Please try again."
    exit 1
  fi

  if id -u "$USERNAME" &>/dev/null; then
    log "User $USERNAME already exists."
    read -p "Do you want to continue setup under $USERNAME? (y/N) " CONTINUE
    if [[ "$CONTINUE" != "y" && "$CONTINUE" != "Y" ]]; then
      err "Aborting setup."
      exit 0
    fi
  else
    if $IS_ROOT; then
      log "Creating user $USERNAME..."
      adduser "$USERNAME"
      usermod -aG sudo "$USERNAME"
      log "User $USERNAME created and added to sudo group."
    else
      err "You must create $USERNAME user for the setup. Please run the script as root."
      exit 1
    fi
  fi

  # Ensure the user’s home dir is at least drwx--x--x (711)
  chmod 711 "/home/$USERNAME"

  # Confirm current user has sudo privileges
  if ! sudo -n true 2>/dev/null; then
    err "Current user does not have sudo privileges."
    if id -u "$USERNAME" &>/dev/null; then
      log "Attempting to add $USERNAME to the sudo group..."
      usermod -aG sudo "$USERNAME"
      verify_command $? "Adding user to sudo"
    else
      err "Cannot add to sudo group. Please add manually."
      exit 1
    fi
  fi

  log "Setting default vim colorscheme to '$VIM_COLORSCHEME' for all users..."
  echo "set background=dark
colorscheme $VIM_COLORSCHEME
" | sudo tee /etc/vim/vimrc.local
  verify_command $? "Setting default vim colorscheme for all users"

  log "Setting vim colorscheme to '$VIM_COLORSCHEME' for user '$USERNAME'..."
  echo "colorscheme $VIM_COLORSCHEME" | sudo -u "$USERNAME" tee "/home/$USERNAME/.vimrc"
  verify_command $? "Setting vim colorscheme for user '$USERNAME'"

  mark_stage_completed "STAGE_2_COMPLETED"
fi

read -n 1 -s -r -p "Press any key to continue to Stage 3..."

###############################################################################
# STAGE 3: Clone the Repository
###############################################################################
log ""
log "--- STAGE 3: Clone the Repository ---"

if is_stage_completed "STAGE_3_COMPLETED"; then
  log "Stage 3 was previously completed. Skipping..."
else
  if [ ! -d "/home/$USERNAME" ]; then
    err "Home directory /home/$USERNAME not found. Did Stage 2 complete?"
    exit 1
  fi

  if [ -d "/home/$USERNAME/$REPO_DIR" ]; then
    log "Repository directory /home/$USERNAME/$REPO_DIR already exists."
    log "Setting $USERNAME as owner of this directory"
    sudo chown -R "$USERNAME":"$USERNAME" "/home/$USERNAME/$REPO_DIR"
    verify_command $? "Ownership transfer complete"
  else
    log "Cloning repository from $REPO_URL to /home/$USERNAME..."
    sudo -u "$USERNAME" mkdir -p "/home/$USERNAME"
    sudo -u "$USERNAME" git clone "$REPO_URL" "/home/$USERNAME/$REPO_DIR"
    verify_command $? "Clone repository"
  fi

  # Make sure the user can read/execute everything in that folder
  sudo chmod -R u+rwx "/home/$USERNAME/$REPO_DIR"

  mark_stage_completed "STAGE_3_COMPLETED"
fi

read -n 1 -s -r -p "Press any key to continue to Stage 4..."

###############################################################################
# STAGE 4: Configure and Deploy
###############################################################################
log ""
log "--- STAGE 4: Configure and Deploy ---"

if is_stage_completed "STAGE_4_COMPLETED"; then
  log "Stage 4 was previously completed. Skipping..."
else
  log "Switching to $USERNAME and completing remaining setup..."

  sudo -u "$USERNAME" bash << 'SUBSHELL'
set -e

# Re-declare verify_command inside the subshell
verify_command() {
  if [ "$1" -ne 0 ]; then
    echo "Verification failed. Aborting at stage: $2"
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
SUBSHELL

  # Mark stage completed
  mark_stage_completed "STAGE_4_COMPLETED"
fi

log "--- STAGE 4 Completed Successfully ---"
log "All stages completed!"
