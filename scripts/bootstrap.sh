#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2154,SC2155

###############################################################################
# n8n Quick Setup Bootstrap Script - Full Feature Edition
#
# Stages:
#   1. System Preparation
#   2. User Setup (root tasks)
#   3. Fail2Ban
#   4. UFW
#   5. Docker
#   6. Clone Repo
#   7. Deploy n8n (Docker Compose)
#
# Includes:
#   - Stage-based approach with skip logic, forced re-run
#   - Logging & color-coded output
#   - Resource checks (disk, memory, CPU, network)
#   - OS check for Ubuntu
#   - Example package version checks
#   - .env handling to avoid invalid image references in Docker Compose
#   - Rollback placeholders
###############################################################################

set -euo pipefail

###############################################################################
# GLOBAL CONFIG & ENVIRONMENT
###############################################################################
export DEBIAN_FRONTEND=noninteractive

SCRIPT_VERSION="0.500"

# Directory to clone the repository into:
REPO_NAME="n8n_quick_setup"
REPO_URL="https://github.com/DavidMcCauley/n8n_quick_setup.git"

# Some default minimum versions
declare -A MIN_PACKAGE_VERSIONS=(
  ["git"]="1:2.25.0"
  ["vim"]="2:8.1.2269"
)

# Stage dependency graph
declare -A STAGE_DEPENDENCIES=(
  ["STAGE_1"]=""      # No dependencies
  ["STAGE_2"]="STAGE_1"
  ["STAGE_3"]="STAGE_2"
  ["STAGE_4"]="STAGE_3"
  ["STAGE_5"]="STAGE_4"
  ["STAGE_6"]="STAGE_5"
  ["STAGE_7"]="STAGE_6"
)

# Rollback skeleton
declare -A ROLLBACK_ACTIONS=(
  ["STAGE_1"]="rollback_stage_1"
  ["STAGE_2"]="rollback_stage_2"
  ["STAGE_3"]="rollback_stage_3"
  ["STAGE_4"]="rollback_stage_4"
  ["STAGE_5"]="rollback_stage_5"
  ["STAGE_6"]="rollback_stage_6"
  ["STAGE_7"]="rollback_stage_7"
)

# Place for storing stage completions, user, etc.
STATUS_FILE="/tmp/n8n_bootstrap_status"
LOG_FILE="/var/log/n8n_bootstrap.log"

# Resource thresholds
MIN_DISK_MB=2048   # e.g. 2GB
MIN_MEM_MB=1024    # e.g. 1GB
MIN_CPU_CORES=1    # e.g. 1 core

# Options that can be passed in
OS_OVERRIDE=false
DRY_RUN=false
INTERACTIVE=false
FORCE_STAGE=""
IS_ROOT=false

###############################################################################
# LOGGING & COLOR SETUP
###############################################################################
if command -v tput &>/dev/null && [ -n "$(tput colors)" ] && [ "$(tput colors)" -ge 8 ]; then
  CLR_RESET="$(tput sgr0)"
  CLR_RED="$(tput setaf 1)"
  CLR_GREEN="$(tput setaf 2)"
  CLR_BLUE="$(tput setaf 4)"
  CLR_YELLOW="$(tput setaf 3)"
else
  CLR_RESET=""
  CLR_RED=""
  CLR_GREEN=""
  CLR_BLUE=""
  CLR_YELLOW=""
fi

log() {
  local ts
  ts=$(date '+%Y-%m-%d %H:%M:%S')
  echo -e "${CLR_GREEN}[LOG]${CLR_RESET} $ts $*" | tee -a "$LOG_FILE"
}

warn() {
  local ts
  ts=$(date '+%Y-%m-%d %H:%M:%S')
  echo -e "${CLR_YELLOW}[WARN]${CLR_RESET} $ts $*" | tee -a "$LOG_FILE"
}

err() {
  local ts
  ts=$(date '+%Y-%m-%d %H:%M:%S')
  echo -e "${CLR_RED}[ERR]${CLR_RESET}  $ts $*" | tee -a "$LOG_FILE" >&2
}

###############################################################################
# ERROR TRAP / DEBUG
###############################################################################
handle_error() {
  local exit_code=$?
  local line_no=$LINENO
  local func_trace="${FUNCNAME[*]:-}"
  local last_cmd="$BASH_COMMAND"

  err "Error on line $line_no: '$last_cmd' (exit: $exit_code)"
  err "Function trace: $func_trace"

  if [ -f "$LOG_FILE" ]; then
    err "Last 50 lines of log:"
    tail -n 50 "$LOG_FILE" >&2
  fi
  exit "$exit_code"
}

# Trap any error
trap 'handle_error' ERR

###############################################################################
# LOG ROTATION (Optional)
###############################################################################
rotate_log_if_needed() {
  if [ -f "$LOG_FILE" ]; then
    local size
    size=$(du -k "$LOG_FILE" | cut -f1)
    if [ "$size" -gt 5120 ]; then  # e.g. 5MB
      mv "$LOG_FILE" "${LOG_FILE}.old-$(date '+%Y%m%d-%H%M%S')"
      touch "$LOG_FILE"
      log "Log file rotated (size > 5MB)."
    fi
  fi
}

###############################################################################
# STAGE STATUS HELPERS
###############################################################################
mark_stage_completed() {
  echo "$1_COMPLETED" >> "$STATUS_FILE"
}

is_stage_completed() {
  grep -qx "$1_COMPLETED" "$STATUS_FILE" 2>/dev/null
}

store_user_in_status() {
  local user="$1"
  sed -i '/^CURRENT_BOOTSTRAP_USER=/d' "$STATUS_FILE" 2>/dev/null || true
  echo "CURRENT_BOOTSTRAP_USER=$user" >> "$STATUS_FILE"
}

read_user_from_status() {
  grep '^CURRENT_BOOTSTRAP_USER=' "$STATUS_FILE" 2>/dev/null | cut -d= -f2 || true
}

###############################################################################
# ROLLBACK ACTIONS
###############################################################################
rollback_stage_1() {
  warn "rollback_stage_1() called. Potential revert of apt changes."
  # For example:
  # apt-get remove --purge -y something
  return 0
}
rollback_stage_2() {
  warn "rollback_stage_2() called. Potential user removal."
  # e.g. userdel -r ...
  return 0
}
rollback_stage_3() {
  warn "rollback_stage_3() called. Potential revert of fail2ban."
  return 0
}
rollback_stage_4() {
  warn "rollback_stage_4() called. Potential revert of UFW."
  return 0
}
rollback_stage_5() {
  warn "rollback_stage_5() called. Potential remove Docker?"
  return 0
}
rollback_stage_6() {
  warn "rollback_stage_6() called. Potential remove the cloned repo?"
  return 0
}
rollback_stage_7() {
  warn "rollback_stage_7() called. Potential remove containers/volumes?"
  return 0
}

stage_rollback() {
  local stage="$1"
  local action="${ROLLBACK_ACTIONS[$stage]}"
  if [ -n "$action" ]; then
    log "Rolling back $stage using $action..."
    if ! $action; then
      err "Rollback failed for $stage"
      return 1
    fi
  fi
  # Remove stage completion marker
  sed -i "/^${stage}_COMPLETED$/d" "$STATUS_FILE" 2>/dev/null || true
  return 0
}

###############################################################################
# STAGE DEPENDENCIES
###############################################################################
check_stage_dependencies() {
  local stage="$1"
  # validate the stage argument
  if [ -z "$stage" ]; then
    err "check_stage_dependencies called without a stage argument."
    return 1
  fi
  # ensure stage is in STAGE_DEPENDENCIES
  if ! [[ ${!STAGE_DEPENDENCIES[@]} =~ "$stage" ]]; then
    err "check_stage_dependencies called with an undefined stage: $stage"
    return 1
  fi
  local dep="${STAGE_DEPENDENCIES[$stage]}"
  if [ -z "$dep" ]; then
    log "Stage $stage has no dependencies."
  else
    # If not completed, we fail
    if ! is_stage_completed "$dep"; then
      err "Stage dependency not met: $stage requires $dep"
      return 1
    fi
  fi
  return 0
}

###############################################################################
# RESOURCE & NETWORK CHECKS
###############################################################################
check_disk_space() {
  local free_mb
  free_mb=$(df -m / | tail -1 | awk '{print $4}')
  if [ "$free_mb" -lt "$MIN_DISK_MB" ]; then
    err "Insufficient disk space: $free_mb MB free (need $MIN_DISK_MB)."
    return 1
  fi
  log "Disk check OK: $free_mb MB free."
  return 0
}

check_memory() {
  local mem_mb
  mem_mb=$(awk '/MemTotal/ {printf "%.0f", $2/1024}' /proc/meminfo)
  if [ "$mem_mb" -lt "$MIN_MEM_MB" ]; then
    err "Insufficient RAM: $mem_mb MB (need $MIN_MEM_MB)."
    return 1
  fi
  log "Memory check OK: $mem_mb MB."
  return 0
}

check_cpu() {
  local cores
  cores=$(nproc)
  if [ "$cores" -lt "$MIN_CPU_CORES" ]; then
    err "Insufficient CPU cores: $cores (need $MIN_CPU_CORES)."
    return 1
  fi
  log "CPU check OK: $cores cores."
  return 0
}

check_network() {
  if ! ping -c 1 google.com &>/dev/null; then
    err "No internet connectivity (ping google.com failed)."
    return 1
  fi
  log "Network check OK."
  return 0
}

###############################################################################
# PACKAGE CHECKS
###############################################################################
check_package_version() {
  local pkg="$1"
  local minv="$2"
  local installedv
  installedv="$(dpkg-query -W -f='${Version}' "$pkg" 2>/dev/null || true)"

  if [ -z "$installedv" ]; then
    log "Package $pkg not installed. Installing..."
    apt-get install -y "$pkg" || return 1
    installedv="$(dpkg-query -W -f='${Version}' "$pkg" 2>/dev/null || true)"
  fi

  if ! dpkg --compare-versions "$installedv" ge "$minv"; then
    log "$pkg version $installedv < required $minv. Upgrading..."
    apt-get install --only-upgrade -y "$pkg" || return 1
    installedv="$(dpkg-query -W -f='${Version}' "$pkg" 2>/dev/null || true)"
  fi

  log "$pkg version $installedv >= $minv"
  return 0
}

verify_command() {
  local code="$1"
  local msg="$2"
  if [ "$code" -ne 0 ]; then
    err "Verification failed => stage: $msg"
    exit 1
  else
    log "Verification passed => $msg"
  fi
}

###############################################################################
# STAGE 1: System Preparation
###############################################################################
stage_1_system_preparation() {
  local STAGE="STAGE_1"
  log ""
  log "--- STAGE 1: System Preparation ---"

  if [ "$FORCE_STAGE" = "1" ]; then
    warn "Forcing STAGE 1 re-run..."
    sed -i '/^STAGE_1_COMPLETED$/d' "$STATUS_FILE" || true
  fi

  check_stage_dependencies "$STAGE" || return 1

  if is_stage_completed "$STAGE"; then
    log "Stage 1 was previously completed. Skipping..."
    return 0
  fi

  # Resource checks
  if ! $DRY_RUN; then
    check_disk_space || { stage_rollback "$STAGE"; return 1; }
    check_memory || { stage_rollback "$STAGE"; return 1; }
    check_cpu || { stage_rollback "$STAGE"; return 1; }
    check_network || { stage_rollback "$STAGE"; return 1; }
  else
    log "Dry run => skipping resource checks"
  fi

  # OS check
  if ! $OS_OVERRIDE; then
    local os_id
    os_id="$(. /etc/os-release; echo "$ID")"
    if [ "$os_id" != "ubuntu" ]; then
      err "Detected OS=$os_id, only 'ubuntu' is supported. (--override-os to skip)"
      stage_rollback "$STAGE"
      return 1
    fi
    log "OS check => ubuntu confirmed."
  else
    warn "OS override => skipping OS checks."
  fi

  if ! $DRY_RUN; then
    apt-get update || verify_command $? "apt update"
    apt-get upgrade -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" || verify_command $? "apt upgrade"
    apt-get autoremove -y || verify_command $? "apt autoremove"

    # Minimum package version checks
    for pkg in "${!MIN_PACKAGE_VERSIONS[@]}"; do
      check_package_version "$pkg" "${MIN_PACKAGE_VERSIONS[$pkg]}" || warn "Could not upgrade $pkg"
    done

    # Check if reboot is required
    if [ -f /var/run/reboot-required ]; then
      log "Reboot required. Re-run script after reboot."
      sleep 3
      reboot
    fi
  else
    log "Dry run => skipping apt tasks"
  fi

  mark_stage_completed "$STAGE"
  log "Stage 1 completed!"
  return 0
}

###############################################################################
# STAGE 2: User Setup (root tasks)
###############################################################################
stage_2_user_setup() {
  local STAGE="STAGE_2"
  log ""
  log "--- STAGE 2: User Setup (root tasks) ---"

  if [ "$FORCE_STAGE" = "2" ]; then
    warn "Forcing STAGE 2 re-run..."
    sed -i '/^STAGE_2_COMPLETED$/d' "$STATUS_FILE" || true
  fi

  check_stage_dependencies "$STAGE" || return 1

  if is_stage_completed "$STAGE"; then
    log "Stage 2 completed, skipping..."
    return 0
  fi

  # Prompt for username
  local USERNAME
  if $INTERACTIVE; then
    read -rp "Please enter the desired username for n8n setup: " USERNAME
  else
    USERNAME="david"
    log "Non-interactive: defaulting to username=$USERNAME"
  fi

  # Validate username
  if [[ ! "$USERNAME" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
    err "Invalid username => $USERNAME"
    stage_rollback "$STAGE"
    return 1
  fi

  if id -u "$USERNAME" &>/dev/null; then
    log "User $USERNAME already exists."
  else
    if ! $DRY_RUN; then
      log "Creating user => $USERNAME"
      adduser "$USERNAME" || { stage_rollback "$STAGE"; return 1; }
      usermod -aG sudo "$USERNAME" || { stage_rollback "$STAGE"; return 1; }
      log "User $USERNAME created + sudo group."
    else
      log "Dry run => would create user: $USERNAME"
    fi
  fi

  store_user_in_status "$USERNAME"

  # Lock down /home/$USERNAME
  if ! $DRY_RUN; then
    chmod 711 "/home/$USERNAME" || { stage_rollback "$STAGE"; return 1; }
  else
    log "Dry run => skip chmod /home/$USERNAME"
  fi

  # Sudo check
  if ! sudo -n true 2>/dev/null; then
    warn "sudo -n true fails, adding $USERNAME to sudo again?"
    usermod -aG sudo "$USERNAME" || true
  fi

  # Optional: set a system-wide vim colorscheme
  if ! $DRY_RUN; then
    log "Setting default vim colorscheme => desert"
    {
      echo "set background=dark"
      echo "colorscheme desert"
    } | tee /etc/vim/vimrc.local >/dev/null || true

    log "Setting user .vimrc => desert"
    echo "colorscheme desert" | sudo -u "$USERNAME" tee "/home/$USERNAME/.vimrc" >/dev/null
  else
    log "Dry run => skip vimrc changes"
  fi

  mark_stage_completed "$STAGE"
  log "Stage 2 completed!"
  return 0
}

###############################################################################
# STAGE 3: Fail2Ban
###############################################################################
stage_3_fail2ban() {
  local STAGE="STAGE_3"
  log ""
  log "--- STAGE 3: Fail2Ban Install/Config ---"

  if [ "$FORCE_STAGE" = "3" ]; then
    warn "Forcing STAGE 3 re-run..."
    sed -i '/^STAGE_3_COMPLETED$/d' "$STATUS_FILE" || true
  fi

  check_stage_dependencies "$STAGE" || return 1

  if is_stage_completed "$STAGE"; then
    log "Stage 3 done. Skipping..."
    return 0
  fi

  if ! $DRY_RUN; then
    log "Installing Fail2Ban..."
    apt-get update && apt-get install -y fail2ban

    # Basic config
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
    log "Fail2Ban installed & configured."
  else
    log "Dry run => skip fail2ban"
  fi

  mark_stage_completed "$STAGE"
  log "Stage 3 completed!"
  return 0
}

###############################################################################
# STAGE 4: UFW Setup
###############################################################################
stage_4_ufw() {
  local STAGE="STAGE_4"
  log ""
  log "--- STAGE 4: UFW Setup ---"

  if [ "$FORCE_STAGE" = "4" ]; then
    warn "Forcing STAGE 4 re-run..."
    sed -i '/^STAGE_4_COMPLETED$/d' "$STATUS_FILE" || true
  fi

  check_stage_dependencies "$STAGE" || return 1

  if is_stage_completed "$STAGE"; then
    log "Stage 4 done. Skipping..."
    return 0
  fi

  if ! $DRY_RUN; then
    log "Configuring UFW..."
    apt-get install -y ufw
    ufw allow OpenSSH
    ufw allow 80/tcp
    ufw allow 443/tcp
    ufw --force enable
    ufw status verbose
    log "UFW configured + enabled."
  else
    log "Dry run => skip UFW"
  fi

  mark_stage_completed "$STAGE"
  log "Stage 4 completed!"
  return 0
}

###############################################################################
# STAGE 5: Docker Setup
###############################################################################
stage_5_docker() {
  local STAGE="STAGE_5"
  log ""
  log "--- STAGE 5: Docker Setup ---"

  if [ "$FORCE_STAGE" = "5" ]; then
    warn "Forcing STAGE 5 re-run..."
    sed -i '/^STAGE_5_COMPLETED$/d' "$STATUS_FILE" || true
  fi

  check_stage_dependencies "$STAGE" || return 1

  if is_stage_completed "$STAGE"; then
    log "Stage 5 done. Skipping..."
    return 0
  fi

  if ! $DRY_RUN; then
    log "Installing Docker + Compose..."
    apt-get update
    apt-get install -y docker.io docker-compose

    local boot_user
    boot_user="$(read_user_from_status)"
    if [ -z "$boot_user" ]; then
      err "BOOT_USER not set => Stage 2 incomplete?"
      stage_rollback "$STAGE"
      return 1
    fi

    usermod -aG docker "$boot_user" || true
    systemctl enable docker

    log "Docker + Docker Compose installed. $boot_user => docker group."
    log "User must log out/in for group membership to take effect."
  else
    log "Dry run => skip Docker"
  fi

  mark_stage_completed "$STAGE"
  log "Stage 5 completed!"
  return 0
}

###############################################################################
# STAGE 6: Clone the n8n_quick_setup Repository
###############################################################################
stage_6_clone_repository() {
  local STAGE="STAGE_6"
  log ""
  log "--- STAGE 6: Clone the Repository ---"

  if [ "$FORCE_STAGE" = "6" ]; then
    warn "Forcing STAGE 6 re-run..."
    sed -i '/^STAGE_6_COMPLETED$/d' "$STATUS_FILE" || true
  fi

  check_stage_dependencies "$STAGE" || return 1

  if is_stage_completed "$STAGE"; then
    log "Stage 6 done. Skipping..."
    return 0
  fi

  local boot_user
  boot_user="$(read_user_from_status)"
  if [ -z "$boot_user" ]; then
    err "No user => stage 2 incomplete?"
    stage_rollback "$STAGE"
    return 1
  fi

  local REPO_PATH="/home/$boot_user/$REPO_NAME"

  if ! $DRY_RUN; then
    if [ -d "$REPO_PATH" ]; then
      log "Repo directory exists => $REPO_PATH; adjusting perms..."
      chown -R "$boot_user":"$boot_user" "$REPO_PATH"
      chmod -R u+rwx "$REPO_PATH" || { stage_rollback "$STAGE"; return 1; }
    else
      log "Cloning repo => $REPO_PATH"
      sudo -u "$boot_user" git clone "$REPO_URL" "$REPO_PATH"
      chown -R "$boot_user":"$boot_user" "$REPO_PATH"
      chmod -R u+rwx "$REPO_PATH"
    fi
  else
    log "Dry run => skip clone"
  fi

  mark_stage_completed "$STAGE"
  log "Stage 6 completed!"
  return 0
}

###############################################################################
# STAGE 7: Deploy n8n (Docker Compose)
###############################################################################
stage_7_deploy_n8n() {
  local STAGE="STAGE_7"
  log ""
  log "--- STAGE 7: Deploy n8n + Docker Compose ---"

  if [ "$FORCE_STAGE" = "7" ]; then
    warn "Forcing STAGE 7 re-run..."
    sed -i '/^STAGE_7_COMPLETED$/d' "$STATUS_FILE" || true
  fi

  check_stage_dependencies "$STAGE" || return 1

  if is_stage_completed "$STAGE"; then
    log "Stage 7 done. Skipping..."
    return 0
  fi

  local boot_user
  boot_user="$(read_user_from_status)"
  if [ -z "$boot_user" ]; then
    err "No user => stage2 incomplete?"
    stage_rollback "$STAGE"
    return 1
  fi

  local REPO_PATH="/home/$boot_user/$REPO_NAME"
  local CONFIG_PATH="$REPO_PATH/config"

  if [ ! -d "$CONFIG_PATH" ]; then
    err "No config/ directory at $CONFIG_PATH => clone step incomplete?"
    stage_rollback "$STAGE"
    return 1
  fi

  # Optionally create .env from .env.example if missing
  if [ ! -f "$CONFIG_PATH/.env" ]; then
    log "Copying .env.example -> .env"
    cp "$CONFIG_PATH/.env.example" "$CONFIG_PATH/.env"
    # Optionally sed out placeholders:
    # sed -i "s|n8n.yourdomain.com|$some_domain|" "$CONFIG_PATH/.env"
  fi

  log "Creating Docker volumes..."
  docker volume create caddy_data || true
  docker volume create n8n_data || true
  docker volume create n8n_postgres_data || true

  log "Starting Docker Compose (docker-compose.yml in config/)..."
  # We cd into config so it picks up .env automatically:
  sudo -u "$boot_user" bash <<EOF
    set -e
    cd "$CONFIG_PATH"
    docker compose -f docker-compose.yml up -d
EOF
  verify_command $? "Docker Compose up"

  mark_stage_completed "$STAGE"
  log "Stage 7 Completed!"
  return 0
}

###############################################################################
# MAIN EXECUTION
###############################################################################
usage() {
  cat <<EOF
Usage: $0 [OPTIONS]

Options:
  --override-os         Skip OS checks
  --force-stageX        Force re-run of stage X (1..7)
  --dry-run             Simulate actions
  --interactive         Prompt for user input
  --help, -h            Show this usage info
EOF
}

rotate_log_if_needed
log "=== n8n Quick Setup Bootstrap v$SCRIPT_VERSION START ==="

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --override-os)
      OS_OVERRIDE=true
      ;;
    --force-stage1|--force-stage2|--force-stage3|--force-stage4|--force-stage5|--force-stage6|--force-stage7)
      FORCE_STAGE="${1//[!0-9]/}"
      ;;
    --dry-run)
      DRY_RUN=true
      ;;
    --interactive)
      INTERACTIVE=true
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      warn "Unrecognized argument => $1"
      ;;
  esac
  shift
done

touch "$STATUS_FILE"
touch "$LOG_FILE"

# Check if running as root
if [ "$(id -u)" -ne 0 ]; then
  if ! sudo -n true 2>/dev/null; then
    err "Needs root/sudo privileges. Re-run with sudo."
    exit 1
  else
    log "Running as non-root user w/ sudo..."
    IS_ROOT=false
  fi
else
  log "Running as root user."
  IS_ROOT=true
fi

# Execute stages in order
stage_1_system_preparation
stage_2_user_setup
stage_3_fail2ban
stage_4_ufw
stage_5_docker
stage_6_clone_repository
stage_7_deploy_n8n

log "All stages completed!"
