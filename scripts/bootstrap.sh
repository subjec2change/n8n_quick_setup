#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2154,SC2155

###############################################################################
# n8n Quick Setup Bootstrap Script - Full Feature (Expanded)
# Version: 0.400
###############################################################################

set -euo pipefail

###############################################################################
# GLOBAL CONFIG & ENVIRONMENT
###############################################################################
export DEBIAN_FRONTEND=noninteractive

SCRIPT_VERSION="0.400"
STATUS_FILE="/tmp/n8n_bootstrap_status"
LOG_FILE="/var/log/n8n_bootstrap.log"

MIN_DISK_MB=2048
MIN_MEM_MB=1024
MIN_CPU_CORES=1

declare -A MIN_PACKAGE_VERSIONS=(
  # If you need more packages at certain minimum versions, add them here
  ["git"]="1:2.25.0"
  ["vim"]="2:8.1.2269"
)

# We’ll keep the same approach for stage dependencies:
declare -A STAGE_DEPENDENCIES=(
  ["STAGE_1"]=""      # No dependency for Stage 1
  ["STAGE_2"]="STAGE_1"
  ["STAGE_3"]="STAGE_2"
  ["STAGE_4"]="STAGE_3"
  ["STAGE_5"]="STAGE_4"
  ["STAGE_6"]="STAGE_5"
  ["STAGE_7"]="STAGE_6"
)

# Rollback placeholders, one for each stage
declare -A ROLLBACK_ACTIONS=(
  ["STAGE_1"]="rollback_stage_1"
  ["STAGE_2"]="rollback_stage_2"
  ["STAGE_3"]="rollback_stage_3"
  ["STAGE_4"]="rollback_stage_4"
  ["STAGE_5"]="rollback_stage_5"
  ["STAGE_6"]="rollback_stage_6"
  ["STAGE_7"]="rollback_stage_7"
)

# Vars for user creation, SSH config, etc.
BOOT_USER=""
SSH_PORT=22

# n8n repository references
REPO_URL="https://github.com/DavidMcCauley/n8n_quick_setup.git"
REPO_DIR="n8n_quick_setup"

OS_OVERRIDE=false
DRY_RUN=false
INTERACTIVE=false
FORCE_STAGE=""
IS_ROOT=false

###############################################################################
# LOGGING + COLORS
###############################################################################
if command -v tput &>/dev/null && [ -n "$(tput colors)" ] && [ "$(tput colors)" -ge 8 ]; then
  CLR_RESET="$(tput sgr0)"
  CLR_RED="$(tput setaf 1)"
  CLR_GREEN="$(tput setaf 2)"
  CLR_YELLOW="$(tput setaf 3)"
else
  CLR_RESET=""
  CLR_RED=""
  CLR_GREEN=""
  CLR_YELLOW=""
fi

log() {
  local ts; ts="$(date '+%Y-%m-%d %H:%M:%S')"
  echo -e "${CLR_GREEN}[LOG]${CLR_RESET} $ts $*" | tee -a "$LOG_FILE"
}

warn() {
  local ts; ts="$(date '+%Y-%m-%d %H:%M:%S')"
  echo -e "${CLR_YELLOW}[WARN]${CLR_RESET} $ts $*" | tee -a "$LOG_FILE"
}

err() {
  local ts; ts="$(date '+%Y-%m-%d %H:%M:%S')"
  echo -e "${CLR_RED}[ERR]${CLR_RESET} $ts $*" | tee -a "$LOG_FILE" >&2
}

###############################################################################
# ERROR HANDLING
###############################################################################
handle_error() {
  local exit_code=$1
  local line_no=$2
  local func_trace=$3
  local last_command=$4

  err "Error on line $line_no: '$last_command' (exit: $exit_code)"
  err "Function trace: $func_trace"

  if [ -f "$LOG_FILE" ]; then
    err "Last 50 lines of log:"
    tail -n 50 "$LOG_FILE" >&2
  fi
  exit "$exit_code"
}
trap 'handle_error $? $LINENO "${FUNCNAME[*]:-}" "$BASH_COMMAND"' ERR

###############################################################################
# STAGE STATUS + ROLLBACK
###############################################################################
mark_stage_completed() {
  echo "$1_COMPLETED" >> "$STATUS_FILE"
}
is_stage_completed() {
  grep -qx "$1_COMPLETED" "$STATUS_FILE" 2>/dev/null
}

rollback_stage_1() { warn "rollback_stage_1: revert apt changes? (placeholder)"; }
rollback_stage_2() { warn "rollback_stage_2: remove created user? (placeholder)"; }
rollback_stage_3() { warn "rollback_stage_3: remove fail2ban? (placeholder)"; }
rollback_stage_4() { warn "rollback_stage_4: revert UFW rules? (placeholder)"; }
rollback_stage_5() { warn "rollback_stage_5: remove Docker? (placeholder)"; }
rollback_stage_6() { warn "rollback_stage_6: remove cloned repo? (placeholder)"; }
rollback_stage_7() { warn "rollback_stage_7: docker-compose down? (placeholder)"; }

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
  sed -i "/^${stage}_COMPLETED$/d" "$STATUS_FILE"
  return 0
}

###############################################################################
# DEPENDENCY CHECK
###############################################################################
check_stage_dependencies() {
  local stage="$1"
  if [ -z "$stage" ]; then
    err "check_stage_dependencies called w/o stage argument!"
    return 1
  fi
  if ! [[ ${!STAGE_DEPENDENCIES[@]} =~ "$stage" ]]; then
    err "Stage $stage not in STAGE_DEPENDENCIES!"
    return 1
  fi
  local dep="${STAGE_DEPENDENCIES[$stage]}"
  if [ -z "$dep" ]; then
    log "Stage $stage has no dependencies."
  else
    if ! is_stage_completed "$dep"; then
      err "Stage dependency not met: $stage requires $dep"
      return 1
    fi
  fi
  return 0
}

###############################################################################
# PACKAGE VERSION CHECK
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
    log "$pkg version $installedv < $minv, upgrading..."
    apt-get install --only-upgrade -y "$pkg" || return 1
    installedv="$(dpkg-query -W -f='${Version}' "$pkg" 2>/dev/null || true)"
  fi
  log "$pkg version $installedv >= $minv"
  return 0
}

###############################################################################
# RESOURCE CHECKS
###############################################################################
check_disk_space() {
  local free_mb
  free_mb="$(df -m / | tail -1 | awk '{print $4}')"
  if [ "$free_mb" -lt "$MIN_DISK_MB" ]; then
    err "Disk free $free_mb MB < required $MIN_DISK_MB MB"
    return 1
  fi
  log "Disk check OK => $free_mb MB free"
}

check_memory() {
  local mem_mb
  mem_mb="$(awk '/MemTotal/ {printf "%.0f", $2/1024}' /proc/meminfo)"
  if [ "$mem_mb" -lt "$MIN_MEM_MB" ]; then
    err "RAM $mem_mb MB < $MIN_MEM_MB MB"
    return 1
  fi
  log "Memory check OK => $mem_mb MB"
}

check_cpu() {
  local cores
  cores="$(nproc)"
  if [ "$cores" -lt "$MIN_CPU_CORES" ]; then
    err "CPU cores $cores < required $MIN_CPU_CORES"
    return 1
  fi
  log "CPU check OK => $cores cores"
}

check_network() {
  if ! ping -c 1 google.com &>/dev/null; then
    err "No network connectivity to google.com"
    return 1
  fi
  log "Network check OK"
}

###############################################################################
# STAGE 1: System Preparation
###############################################################################
stage_1_system_preparation() {
  local STAGE="STAGE_1"
  log ""
  log "--- STAGE 1: System Preparation ---"

  if [ "$FORCE_STAGE" = "1" ]; then
    warn "Forcing stage 1 re-run..."
    sed -i "/^${STAGE}_COMPLETED$/d" "$STATUS_FILE" || true
  fi

  check_stage_dependencies "$STAGE" || return 1

  if is_stage_completed "$STAGE"; then
    log "Stage 1 was previously completed. Skipping..."
    return 0
  fi

  # This is effectively the old "system prep" steps
  check_disk_space || { stage_rollback "$STAGE"; return 1; }
  check_memory     || { stage_rollback "$STAGE"; return 1; }
  check_cpu        || { stage_rollback "$STAGE"; return 1; }
  check_network    || { stage_rollback "$STAGE"; return 1; }

  # Docker might not be installed => just a warning
  if ! command -v docker &>/dev/null; then
    warn "Docker not installed => skipping Docker health check."
  else
    if ! docker ps &>/dev/null; then
      warn "Docker daemon not running? You might need to 'systemctl start docker'."
    fi
  fi

  # Check OS
  if ! $OS_OVERRIDE; then
    local os_id; os_id="$(. /etc/os-release; echo "$ID")"
    if [ "$os_id" != "ubuntu" ]; then
      err "Detected OS=$os_id, only 'ubuntu' supported. Use --override-os to skip."
      stage_rollback "$STAGE"
      return 1
    fi
    log "OS check => ubuntu confirmed."
  else
    warn "OS override => skipping OS checks"
  fi

  # do apt updates
  if ! $DRY_RUN; then
    apt-get update || true
    apt-get upgrade -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" || true
    apt-get autoremove -y || true

    for pkg in "${!MIN_PACKAGE_VERSIONS[@]}"; do
      check_package_version "$pkg" "${MIN_PACKAGE_VERSIONS[$pkg]}" || warn "Could not meet $pkg version requirement"
    done
  else
    log "Dry-run => skipping apt tasks"
  fi

  mark_stage_completed "$STAGE"
  log "--- STAGE 1 Completed ---"
  return 0
}

###############################################################################
# STAGE 2: User Setup + SSH Hardening  (merged from setup-user.sh)
###############################################################################
stage_2_user_setup() {
  local STAGE="STAGE_2"
  log ""
  log "--- STAGE 2: User Setup (root tasks) ---"

  if [ "$FORCE_STAGE" = "2" ]; then
    warn "Forcing stage 2 re-run..."
    sed -i "/^${STAGE}_COMPLETED$/d" "$STATUS_FILE" || true
  fi

  check_stage_dependencies "$STAGE" || return 1

  if is_stage_completed "$STAGE"; then
    log "Stage 2 completed, skipping..."
    return 0
  fi

  # EXACT lines from old setup-user.sh:
  #   adduser $USERNAME
  #   usermod -aG sudo $USERNAME
  #   secure ssh
  #   etc.

  if $INTERACTIVE; then
    read -rp "Please enter the desired username for n8n setup: " BOOT_USER
    read -rp "SSH port? [22]: " TMP_PORT
    if [ -n "$TMP_PORT" ]; then
      SSH_PORT="$TMP_PORT"
    fi
  else
    [ -z "$BOOT_USER" ] && BOOT_USER="david"
    [ -z "$SSH_PORT" ] && SSH_PORT="22"
    log "Non-interactive => Using BOOT_USER=$BOOT_USER, SSH_PORT=$SSH_PORT"
  fi

  if [[ ! "$BOOT_USER" =~ ^[a-zA-Z_][a-zA-Z0-9_-]*$ ]]; then
    err "Invalid username => '$BOOT_USER'"
    stage_rollback "$STAGE"
    return 1
  fi

  if ! id -u "$BOOT_USER" &>/dev/null; then
    # from setup-user.sh
    log "Creating user => $BOOT_USER"
    if ! $DRY_RUN; then
      adduser "$BOOT_USER"     # old script line
      usermod -aG sudo "$BOOT_USER"
    else
      log "Dry-run => skip user creation"
    fi
  else
    warn "User $BOOT_USER already exists, continuing..."
  fi

  # SSH Hardening:
  if ! $DRY_RUN; then
    mkdir -p "/home/$BOOT_USER/.ssh"
    chmod 700 "/home/$BOOT_USER/.ssh"
    if [ -f ~/.ssh/authorized_keys ]; then
      cp ~/.ssh/authorized_keys "/home/$BOOT_USER/.ssh/authorized_keys" || true
    fi
    chown -R "$BOOT_USER:$BOOT_USER" "/home/$BOOT_USER/.ssh"

    sed -i "s/#Port 22/Port $SSH_PORT/" /etc/ssh/sshd_config
    sed -i "s/PermitRootLogin yes/PermitRootLogin no/" /etc/ssh/sshd_config
    sed -i "s/#PasswordAuthentication yes/PasswordAuthentication no/" /etc/ssh/sshd_config

    systemctl restart ssh
    log "User $BOOT_USER created + SSH locked down. SSH port => $SSH_PORT"
  else
    log "Dry-run => skip SSH config changes"
  fi

  mark_stage_completed "$STAGE"
  log "--- STAGE 2 Completed ---"
  return 0
}

###############################################################################
# STAGE 3: Fail2Ban (merged from setup-fail2ban.sh)
###############################################################################
stage_3_fail2ban() {
  local STAGE="STAGE_3"
  log ""
  log "--- STAGE 3: Fail2Ban Install/Config ---"

  if [ "$FORCE_STAGE" = "3" ]; then
    warn "Forcing stage 3 re-run..."
    sed -i "/^${STAGE}_COMPLETED$/d" "$STATUS_FILE" || true
  fi

  check_stage_dependencies "$STAGE" || return 1

  if is_stage_completed "$STAGE"; then
    log "Stage 3 done. Skipping..."
    return 0
  fi

  # EXACT lines from setup-fail2ban.sh
  if ! $DRY_RUN; then
    log "Installing Fail2Ban..."
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
    log "Fail2Ban installed + basic config added."
  else
    log "Dry-run => skipping fail2ban install/config"
  fi

  mark_stage_completed "$STAGE"
  log "--- STAGE 3 Completed ---"
  return 0
}

###############################################################################
# STAGE 4: UFW (merged from setup-ufw.sh)
###############################################################################
stage_4_ufw() {
  local STAGE="STAGE_4"
  log ""
  log "--- STAGE 4: UFW Setup ---"

  if [ "$FORCE_STAGE" = "4" ]; then
    warn "Forcing stage 4 re-run..."
    sed -i "/^${STAGE}_COMPLETED$/d" "$STATUS_FILE" || true
  fi

  check_stage_dependencies "$STAGE" || return 1

  if is_stage_completed "$STAGE"; then
    log "Stage 4 done. Skipping..."
    return 0
  fi

  # EXACT lines from setup-ufw.sh
  if ! $DRY_RUN; then
    log "Configuring UFW..."
    apt install -y ufw
    ufw allow OpenSSH
    ufw allow 80/tcp
    ufw allow 443/tcp

    # If SSH_PORT != 22, we allow that
    if [ "$SSH_PORT" != "22" ]; then
      ufw allow "$SSH_PORT/tcp"
    fi

    ufw --force enable
    ufw status verbose
    log "UFW configured + enabled."
  else
    log "Dry-run => skipping UFW tasks"
  fi

  mark_stage_completed "$STAGE"
  log "--- STAGE 4 Completed ---"
  return 0
}

###############################################################################
# STAGE 5: Docker (merged from setup-docker.sh)
###############################################################################
stage_5_docker() {
  local STAGE="STAGE_5"
  log ""
  log "--- STAGE 5: Docker Setup ---"

  if [ "$FORCE_STAGE" = "5" ]; then
    warn "Forcing stage 5 re-run..."
    sed -i "/^${STAGE}_COMPLETED$/d" "$STATUS_FILE" || true
  fi

  check_stage_dependencies "$STAGE" || return 1

  if is_stage_completed "$STAGE"; then
    log "Stage 5 done. Skipping..."
    return 0
  fi

  # EXACT lines from setup-docker.sh
  if ! $DRY_RUN; then
    log "Installing Docker + Compose..."
    apt update && apt install -y docker.io docker-compose

    # Add user to Docker group
    if [ -z "$BOOT_USER" ]; then
      err "BOOT_USER not set => Stage 2 incomplete?"
      stage_rollback "$STAGE"
      return 1
    fi
    usermod -aG docker "$BOOT_USER"
    systemctl enable docker
    systemctl start docker

    log "Docker + Docker Compose installed. $BOOT_USER => docker group."
    log "User must log out/in for group membership to take effect."
  else
    log "Dry-run => skipping Docker tasks"
  fi

  mark_stage_completed "$STAGE"
  log "--- STAGE 5 Completed ---"
  return 0
}

###############################################################################
# STAGE 6: Clone the Repository (part of original bootstrap or separate script)
###############################################################################
stage_6_clone() {
  local STAGE="STAGE_6"
  log ""
  log "--- STAGE 6: Clone the Repository ---"

  if [ "$FORCE_STAGE" = "6" ]; then
    warn "Forcing stage 6 re-run..."
    sed -i "/^${STAGE}_COMPLETED$/d" "$STATUS_FILE" || true
  fi

  check_stage_dependencies "$STAGE" || return 1

  if is_stage_completed "$STAGE"; then
    log "Stage 6 done. Skipping..."
    return 0
  fi

  # Make sure we have a user
  if [ -z "$BOOT_USER" ]; then
    err "BOOT_USER not set => Stage 2 incomplete?"
    stage_rollback "$STAGE"
    return 1
  fi

  local home_dir="/home/$BOOT_USER"
  if [ ! -d "$home_dir" ]; then
    err "Missing home dir => $home_dir. Stage 2 incomplete?"
    stage_rollback "$STAGE"
    return 1
  fi

  if ! $DRY_RUN; then
    if [ -d "$home_dir/$REPO_DIR" ]; then
      log "Repo directory exists => $home_dir/$REPO_DIR; fixing perms only"
      chown -R "$BOOT_USER:$BOOT_USER" "$home_dir/$REPO_DIR"
      chmod -R u+rwx "$home_dir/$REPO_DIR"
    else
      sudo -u "$BOOT_USER" git clone "$REPO_URL" "$home_dir/$REPO_DIR"
      chown -R "$BOOT_USER:$BOOT_USER" "$home_dir/$REPO_DIR"
      chmod -R u+rwx "$home_dir/$REPO_DIR"
    fi
  else
    log "Dry-run => skip cloning repository"
  fi

  mark_stage_completed "$STAGE"
  log "--- STAGE 6 Completed ---"
  return 0
}

###############################################################################
# STAGE 7: Deploy n8n + Docker Compose (like deploy-n8n.sh)
###############################################################################
stage_7_deploy() {
  local STAGE="STAGE_7"
  log ""
  log "--- STAGE 7: Deploy n8n + Docker Compose ---"

  if [ "$FORCE_STAGE" = "7" ]; then
    warn "Forcing stage 7 re-run..."
    sed -i "/^${STAGE}_COMPLETED$/d" "$STATUS_FILE" || true
  fi

  check_stage_dependencies "$STAGE" || return 1

  if is_stage_completed "$STAGE"; then
    log "Stage 7 done. Skipping..."
    return 0
  fi

  # EXACT lines from deploy-n8n.sh (plus minor expansions)
  if [ -z "$BOOT_USER" ]; then
    err "BOOT_USER not set => Stage 2 incomplete?"
    stage_rollback "$STAGE"
    return 1
  fi
  local home_dir="/home/$BOOT_USER"
  if [ ! -d "$home_dir/$REPO_DIR" ]; then
    err "Repo not found => $home_dir/$REPO_DIR. Stage 6 incomplete?"
    stage_rollback "$STAGE"
    return 1
  fi

  if ! $DRY_RUN; then
    sudo -u "$BOOT_USER" bash <<EOF
set -e
cd "$home_dir/$REPO_DIR"

# Original lines from deploy-n8n.sh:
echo "[LOG] Creating Docker volumes..."
docker volume create caddy_data
docker volume create n8n_data

echo "[LOG] Starting Docker Compose (docker-compose.yml in config/)..."
docker compose -f config/docker-compose.yml up -d

echo "[LOG] n8n + Caddy deployed successfully."
EOF
  else
    log "Dry-run => skip docker compose up -d"
  fi

  mark_stage_completed "$STAGE"
  log "--- STAGE 7 Completed ---"
  log "All stages completed!"
  return 0
}

###############################################################################
# MAIN
###############################################################################
usage() {
  cat <<EOF
Usage: $0 [OPTIONS]

Options:
  --override-os       Skip OS checks (dangerous).
  --force-stageX      Re-run a specific stage X (1..7).
  --dry-run           Simulate actions, no changes.
  --interactive       Prompt user for config (username/port).
  --help, -h          Show usage
EOF
}

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

if [ "$(id -u)" -ne 0 ]; then
  if ! sudo -n true 2>/dev/null; then
    err "Script requires root or passwordless sudo. Rerun with sudo."
    exit 1
  else
    log "Running as non-root user with sudo privileges..."
    IS_ROOT=false
  fi
else
  log "Running as root user."
  IS_ROOT=true
fi

touch "$STATUS_FILE" "$LOG_FILE"
log "=== n8n Quick Setup Bootstrap v$SCRIPT_VERSION START ==="

# RUN STAGES
stage_1_system_preparation
stage_2_user_setup
stage_3_fail2ban
stage_4_ufw
stage_5_docker
stage_6_clone
stage_7_deploy

log "=== n8n Quick Setup Bootstrap COMPLETE ==="
exit 0
