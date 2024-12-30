#!/bin/bash
set -e

###############################################################################
# n8n Quick Setup Bootstrap Script
#  - Enhanced logging of permissions
#  - Persists the chosen username in a status file for Stage 4 usage
#  - Idempotent: can safely rerun multiple times
#
# Version: 0.070
###############################################################################

###############################################################################
# GLOBAL CONFIG & ENVIRONMENT
###############################################################################
export DEBIAN_FRONTEND=noninteractive

SCRIPT_VERSION="0.070"
REPO_URL="https://github.com/DavidMcCauley/n8n_quick_setup.git"
REPO_DIR="n8n_quick_setup"
USER_NAME_PROMPT="Please enter the desired username for n8n setup:"
VIM_COLORSCHEME="desert"
STATUS_FILE="/tmp/n8n_bootstrap_status"

###############################################################################
# HELPER FUNCTIONS
###############################################################################
log()  { echo -e "[LOG] $*"; }
err()  { echo -e "[ERR] $*" >&2; }

check_program() {
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

mark_stage_completed() {
  # Writes a marker line into the status file
  echo "$1" >> "$STATUS_FILE"
}

is_stage_completed() {
  # Checks if the status file contains a specific line
  grep -qx "$1" "$STATUS_FILE" 2>/dev/null
}

store_user_in_status() {
  # If a user is chosen, store it in status file as: CURRENT_BOOTSTRAP_USER=david
  sed -i '/^CURRENT_BOOTSTRAP_USER=/d' "$STATUS_FILE" 2>/dev/null || true
  echo "CURRENT_BOOTSTRAP_USER=$1" >> "$STATUS_FILE"
}

read_user_from_status() {
  # Parse the user name from a line like: CURRENT_BOOTSTRAP_USER=david
  grep '^CURRENT_BOOTSTRAP_USER=' "$STATUS_FILE" 2>/dev/null | cut -d= -f2
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

  # Determine if any upgrades actually happened
  if [ "$UPDATES" -gt 1 ]; then
    UPDATES_APPLIED=true
  else
    UPDATES_APPLIED=false
  fi

  REBOOT_REQUIRED="$(ls /var/run/reboot-required 2>/dev/null || true)"
  if [ -n "$REBOOT_REQUIRED" ] && $UPDATES_APPLIED; then
    log "--- STAGE 1 Requires Reboot ---"
    log "A system reboot is required to complete updates."
    if [ "$IS_ROOT" = true ]; then
      REBOOT_CMD="./bootstrap.sh"
    else
      REBOOT_CMD="sudo ./bootstrap.sh"
    fi
    log "After reboot, rerun the script with: $REBOOT_CMD"
    log "Rebooting in 5 seconds..."
    sleep 5
    sudo reboot
  fi

  if $UPDATES_APPLIED; then
    log "--- STAGE 1 Completed With Changes ---"
  else
    log "--- STAGE 1 Completed Without Changes ---"
  fi

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
    err "Username cannot be empty."
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

  # Store the user in the status file so we can read it in Stage 4
  store_user_in_status "$USERNAME"

  # Log the current permission on /home/$USERNAME
  log "Before chmod, /home/$USERNAME permission is:"
  ls -ld "/home/$USERNAME" || true

  # Ensure the user’s home dir is at least drwx--x--x (711)
  log "Applying 711 to /home/$USERNAME..."
  chmod 711 "/home/$USERNAME"

  log "After chmod, /home/$USERNAME permission is:"
  ls -ld "/home/$USERNAME" || true

  # Confirm we (the script runner) have sudo privileges
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

  # Set the default vim colorscheme for all users
  log "Setting default vim colorscheme to '$VIM_COLORSCHEME' (via /etc/vim/vimrc.local)..."
  echo "set background=dark
colorscheme $VIM_COLORSCHEME
" | sudo tee /etc/vim/vimrc.local
  verify_command $? "Setting default vim colorscheme for all users"

  # Also set a personal .vimrc for the chosen user
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
  # Retrieve the chosen user from the status file
  BOOT_USER="$(read_user_from_status)"
  if [ -z "$BOOT_USER" ]; then
    err "No user found in status file. Did Stage 2 complete?"
    exit 1
  fi

  if [ ! -d "/home/$BOOT_USER" ]; then
    err "Home directory /home/$BOOT_USER not found. Did Stage 2 complete?"
    exit 1
  fi

  if [ -d "/home/$BOOT_USER/$REPO_DIR" ]; then
    log "Repository directory /home/$BOOT_USER/$REPO_DIR already exists."
    log "Setting $BOOT_USER as owner of this directory"
    sudo chown -R "$BOOT_USER":"$BOOT_USER" "/home/$BOOT_USER/$REPO_DIR"
    verify_command $? "Ownership transfer complete"
  else
    log "Cloning repository from $REPO_URL to /home/$BOOT_USER..."
    sudo -u "$BOOT_USER" mkdir -p "/home/$BOOT_USER"
    sudo -u "$BOOT_USER" git clone "$REPO_URL" "/home/$BOOT_USER/$REPO_DIR"
    verify_command $? "Clone repository"
  fi

  log "Before chmod, /home/$BOOT_USER/$REPO_DIR permission is:"
  ls -ld "/home/$BOOT_USER/$REPO_DIR" || true

  log "Applying u+rwx to /home/$BOOT_USER/$REPO_DIR..."
  sudo chmod -R u+rwx "/home/$BOOT_USER/$REPO_DIR"

  log "After chmod, /home/$BOOT_USER/$REPO_DIR permission is:"
  ls -ld "/home/$BOOT_USER/$REPO_DIR" || true

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
  # Retrieve the chosen user from the status file
  BOOT_USER="$(read_user_from_status)"
  if [ -z "$BOOT_USER" ]; then
    err "No user found. Did Stage 2 complete?"
    exit 1
  fi

  log "Switching to $BOOT_USER and completing remaining setup..."

  sudo -u "$BOOT_USER" bash << 'HEREDOC'
    set -e

    verify_command() {
      if [ "$1" -ne 0 ]; then
        echo "[ERR] Verification failed. Aborting at stage: $2"
        exit 1
      else
        echo "[LOG] Verification passed for: $2"
      fi
    }

    echo "[LOG] Moving into n8n_quick_setup..."
    cd "n8n_quick_setup"

    echo "[LOG] Setting execute permissions on scripts..."
    chmod +x scripts/*.sh
    verify_command $? "Setting permissions"

    echo "[LOG] Running setup scripts..."
    ./scripts/setup-user.sh "$USER"
    verify_command $? "Running setup-user.sh"

    ./scripts/setup-fail2ban.sh
    verify_command $? "Running setup-fail2ban.sh"

    ./scripts/setup-ufw.sh
    verify_command $? "Running setup-ufw.sh"

    ./scripts/setup-docker.sh "$USER"
    verify_command $? "Running setup-docker.sh"

    echo "[LOG] Bootstrap process completed."
    echo "[LOG] Navigate to the n8n_quick_setup folder to proceed with the next steps in the README."
HEREDOC

  mark_stage_completed "STAGE_4_COMPLETED"
  log "--- STAGE 4 Completed Successfully ---"
  log "All stages completed!"
fi
