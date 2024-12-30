#!/bin/bash

set -e

# Set environment variable for noninteractive prompts
export DEBIAN_FRONTEND=noninteractive

# Variables
REPO_URL="https://github.com/DavidMcCauley/n8n_quick_setup.git"
REPO_DIR="n8n_quick_setup"
USER_NAME_PROMPT="Please enter the desired username for n8n setup:"
CURRENT_USER=$(whoami)
VIM_COLORSCHEME="desert"  # Default colorscheme
SCRIPT_VERSION="0.048"

# Function to check for a program
check_program() {
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

# Function to verify command success
verify_command() {
    if [ $1 -ne 0 ]; then
        echo "Verification failed. Aborting the script at stage: $2"
        exit 1
    else
        echo "Verification passed for: $2"
    fi
}

# Check if running as root or with sudo
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

# --- STAGE 1: System Preparation ---
echo "--- STAGE 1: System Preparation ---"

# Update and Upgrade apt
echo "Updating and Upgrading apt packages..."
apt update
UPDATES=$(apt list --upgradable 2>/dev/null | wc -l)
apt upgrade -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" -y
verify_command $? "apt update && apt upgrade -y"

# Autoremove unnecessary packages
echo "Removing unnecessary packages..."
apt autoremove -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" -y
verify_command $? "apt autoremove -y"

# Check for git
check_program git
verify_command $? "git install check"

# Check for vim
check_program vim
verify_command $? "vim install check"

# Check if updates were applied
if [ "$UPDATES" -gt 1 ]; then
    UPDATES_APPLIED=true
else
    UPDATES_APPLIED=false
fi

# Check if a reboot is needed
REBOOT_REQUIRED=$(ls /var/run/reboot-required 2> /dev/null)
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
    if $IS_ROOT; then
      echo "Creating user $USERNAME..."
      adduser "$USERNAME"
      usermod -aG sudo "$USERNAME"
      echo "User $USERNAME created and added to sudo group."
    else
      echo "You must create $USERNAME user for the setup. Please run the script as root to do this, or create the user manually and add to the sudo group"
      exit 1
    fi

fi

# Check if current user has sudo privileges
if ! sudo -n true 2>/dev/null; then
    echo "Current user does not have sudo privileges."
    if id -u "$USERNAME" &> /dev/null; then
        echo "Attempting to add $USERNAME to the sudo group..."
        usermod -aG sudo "$USERNAME"
        verify_command $? "Adding user to sudo"
    else
        echo "Cannot add to sudo group. Please add the user to the sudo group."
        exit 1
    fi
fi

# Set the default vim colorscheme for all users
echo "Setting default vim colorscheme to 'desert' for all users..."
echo "set background=dark
colorscheme $VIM_COLORSCHEME
" | sudo tee /etc/vim/vimrc.local
verify_command $? "Setting default vim colorscheme for all users"

# Set a better vim colorscheme for current user
echo "Setting vim colorscheme to '$VIM_COLORSCHEME' for user '$USERNAME'..."
echo "colorscheme $VIM_COLORSCHEME" | sudo -u "$USERNAME" tee /home/"$USERNAME"/.vimrc
verify_command $? "Setting vim colorscheme for user '$USERNAME'"

read -n 1 -s -r -p "Press any key to continue to Stage 2..."

# --- STAGE 2: Clone the Repository ---
echo "--- STAGE 2: Clone the Repository ---"

# Check if target directory exists for the new user
if [ -d "/home/$USERNAME/$REPO_DIR" ]; then
    echo "Repository directory /home/$USERNAME/$REPO_DIR already exists."
    echo "Setting $USERNAME as owner of this directory"
    sudo chown -R "$USERNAME":"$USERNAME" "/home/$USERNAME/$REPO_DIR"
    verify_command $? "Ownership transfer complete"
else
    # Clone the repo to the user home directory
    echo "Cloning repository from $REPO_URL to /home/$USERNAME..."
    sudo -u "$USERNAME" mkdir -p "/home/$USERNAME"
    sudo -u "$USERNAME" git clone "$REPO_URL" "/home/$USERNAME/$REPO_DIR"
    verify_command $? "Clone repository"
fi
echo "--- STAGE 2 Completed Successfully ---"
read -n 1 -s -r -p "Press any key to continue to Stage 3..."

# --- STAGE 3: Configure and Deploy ---
echo "--- STAGE 3: Configure and Deploy ---"

# Switch to the new user, and run setup scripts
echo "Switching to $USERNAME and completing remaining setup..."
sudo -u "$USERNAME" bash << EOF
  cd "$REPO_DIR"

    # Set execution permissions on the scripts
    echo "Setting execute permissions on scripts..."
    chmod +x scripts/*.sh
    verify_command $? "Setting permissions"

    # Perform the setup steps
    echo "Running setup scripts..."
    ./scripts/setup-user.sh "$USERNAME"
    verify_command $? "Running setup-user.sh"
    ./scripts/setup-fail2ban.sh
    verify_command $? "Running setup-fail2ban.sh"
    ./scripts/setup-ufw.sh
    verify_command $? "Running setup-ufw.sh"
    ./scripts/setup-docker.sh "$USERNAME"
    verify_command $? "Running setup-docker.sh"

    echo "Bootstrap process completed."
    echo "Navigate to the $REPO_DIR folder to proceed with the next steps in the README."
EOF
echo "--- STAGE 3 Completed Successfully ---"
