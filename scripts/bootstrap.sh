#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2154,SC2155

###############################################################################
# n8n Quick Setup Bootstrap Script - Full Feature Edition (Enhanced)
# Version: 0.131
#
# Changelog vs 0.130:
#   1. Fixed unbound variable error in STAGE_DEPENDENCIES for STAGE_1.
#   2. Added defensive checks in check_stage_dependencies().
###############################################################################

set -euo pipefail

###############################################################################
# GLOBAL CONFIG & ENVIRONMENT
###############################################################################
export DEBIAN_FRONTEND=noninteractive

SCRIPT_VERSION="0.131"

# Default configs (env-overridable)
REPO_URL="${REPO_URL:-https://github.com/DavidMcCauley/n8n_quick_setup.git}"
REPO_DIR="${REPO_DIR:-n8n_quick_setup}"
USER_NAME_PROMPT="${USER_NAME_PROMPT:-Please enter the desired username for n8n setup:}"
VIM_COLORSCHEME="${VIM_COLORSCHEME:-desert}"

STATUS_FILE="${STATUS_FILE:-/tmp/n8n_bootstrap_status}"
LOG_FILE="${LOG_FILE:-/var/log/n8n_bootstrap.log}"

MIN_DISK_MB="${MIN_DISK_MB:-2048}"     # Require at least 2GB free
MIN_MEM_MB="${MIN_MEM_MB:-1024}"       # Require at least 1GB of RAM
MIN_CPU_CORES="${MIN_CPU_CORES:-1}"    # Require at least 1 CPU core

# Minimum package versions (add or adjust as needed)
declare -A MIN_PACKAGE_VERSIONS=(
  ["git"]="${GIT_MIN_VERSION:-1:2.25.0}"
  ["vim"]="${VIM_MIN_VERSION:-2:8.1.2269}"
  # Example: ["docker"]="5:20.10.0"
)

# -----------------------------------------------------------------------------
# Stage dependency graph
# NOTE: We explicitly initialize STAGE_1 with an empty string to avoid unbound variable issues.
# -----------------------------------------------------------------------------
declare -A STAGE_DEPENDENCIES=(
  ["STAGE_1"]=""      # STAGE_1 has no dependencies
  ["STAGE_2"]="STAGE_1"
  ["STAGE_3"]="STAGE_2"
  ["STAGE_4"]="STAGE_3"
)

# Rollback skeleton (customizable)
declare -A ROLLBACK_ACTIONS=(
  ["STAGE_1"]="rollback_stage_1"
  ["STAGE_2"]="rollback_stage_2"
  ["STAGE_3"]="rollback_stage_3"
  ["STAGE_4"]="rollback_stage_4"
)

# Optional progress tracking
declare -A STAGE_PROGRESS

OS_OVERRIDE=false
VERBOSE=false
DRY_RUN=false
INTERACTIVE=false
FORCE_STAGE=""
IS_ROOT=false

###############################################################################
# LOGGING & COLOR
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
  local msg="$*"
  local ts
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  echo -e "${CLR_GREEN}[LOG]${CLR_RESET} $ts $msg" | tee -a "$LOG_FILE"
}

warn() {
  local msg="$*"
  local ts
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  echo -e "${CLR_YELLOW}[WARN]${CLR_RESET} $ts $msg" | tee -a "$LOG_FILE"
}

err() {
  local msg="$*"
  local ts
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  echo -e "${CLR_RED}[ERR]${CLR_RESET} $ts $msg" | tee -a "$LOG_FILE" >&2
}

###############################################################################
# ERROR TRAP
###############################################################################
handle_error() {
  local line_no="$1"
  local func_trace="$2"
  local last_command="$3"
  local exit_code=$?

  err "Error on line $line_no: '$last_command' (exit: $exit_code)"
  err "Function trace: $func_trace"

  if [ -f "$LOG_FILE" ]; then
    err "Last 50 lines of log:"
    tail -n 50 "$LOG_FILE" >&2
  fi
  exit "$exit_code"
}

trap 'handle_error "$LINENO" "${FUNCNAME[*]:-}" "$BASH_COMMAND"' ERR

###############################################################################
# LOG ROTATION
###############################################################################
rotate_log_if_needed() {
  if [ -f "$LOG_FILE" ]; then
    local size
    size="$(du -k "$LOG_FILE" | cut -f1)"
    if [ "$size" -gt 5120 ]; then
      mv "$LOG_FILE" "${LOG_FILE}.old-$(date '+%Y%m%d_%H%M%S')"
      touch "$LOG_FILE"
      log "Log file rotated (size > 5MB)."
    fi
  fi
}

###############################################################################
# CONFIG VALIDATION
###############################################################################
validate_config() {
  local required_vars=(
    "REPO_URL"
    "REPO_DIR"
    "USER_NAME_PROMPT"
    "VIM_COLORSCHEME"
  )
  for var in "${required_vars[@]}"; do
    if [ -z "${!var}" ]; then
      err "Required config var $var not set!"
      return 1
    fi
  done
  log "Configuration validation passed."
}

###############################################################################
# STAGE STATUS
###############################################################################
mark_stage_completed() {
  echo "$1" >> "$STATUS_FILE"
}

is_stage_completed() {
  grep -qx "$1" "$STATUS_FILE" 2>/dev/null
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
  # Example: remove installed packages, restore configs, etc.
  # apt-get remove --purge -y <packages> || true
  return 0
}

rollback_stage_2() {
  warn "rollback_stage_2() called. Potential user removal."
  local user
  user="$(read_user_from_status || true)"
  if [ -n "$user" ]; then
    warn "Removing user $user (placeholder)."
    # userdel -r "$user" || true
  fi
  return 0
}

rollback_stage_3() {
  warn "rollback_stage_3() called. Potential removal of the cloned repo."
  local user
  user="$(read_user_from_status || true)"
  if [ -n "$user" ]; then
    rm -rf "/home/$user/$REPO_DIR" || true
  fi
  return 0
}

rollback_stage_4() {
  warn "rollback_stage_4() called. Potential cleanup of containers."
  # Example: docker rm -f some_container || true
  return 0
}

stage_rollback() {
  local stage="$1"
  local action="${ROLLBACK_ACTIONS[$stage]:-}"

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
# STAGE DEPENDENCIES (FIXED + DEFENSIVE)
###############################################################################
check_stage_dependencies() {
  local stage="$1"

  # 1. Validate that a stage argument was provided:
  if [ -z "$stage" ]; then
    err "check_stage_dependencies called without a stage argument."
    return 1
  fi

  # 2. Ensure $stage is defined in STAGE_DEPENDENCIES:
  #    The +_ expansion avoids unbound variable errors even under `set -u`.
  if [ -z "${STAGE_DEPENDENCIES[$stage]+_}" ]; then
    err "check_stage_dependencies called with an undefined stage: $stage"
    return 1
  fi

  # 3. Grab the dependency
  local dep="${STAGE_DEPENDENCIES[$stage]}"

  # 4. If dep is empty, no dependencies. Otherwise check if the dep is completed.
  if [ -z "$dep" ]; then
    log "Stage $stage has no dependencies."
  elif ! is_stage_completed "${dep}_COMPLETED"; then
    err "Stage dependency not met: $stage requires $dep"
    return 1
  fi

  return 0
}

###############################################################################
# HEALTH CHECKS
###############################################################################
check_disk_space() {
  local free_mb
  free_mb="$(df -m / | tail -1 | awk '{print $4}')"
  if [ "$free_mb" -lt "$MIN_DISK_MB" ]; then
    err "Insufficient disk space: $free_mb MB free (need $MIN_DISK_MB)."
    return 1
  fi
  log "Disk check OK: $free_mb MB free."
  return 0
}

check_memory() {
  local mem_mb
  mem_mb="$(awk '/MemTotal/ {printf "%.0f", $2/1024}' /proc/meminfo)"
  if [ "$mem_mb" -lt "$MIN_MEM_MB" ]; then
    err "Insufficient RAM: $mem_mb MB (need $MIN_MEM_MB)."
    return 1
  fi
  log "Memory check OK: $mem_mb MB."
  return 0
}

check_cpu() {
  local cores
  cores="$(nproc)"
  if [ "$cores" -lt "$MIN_CPU_CORES" ]; then
    err "Insufficient CPU cores: $cores (need $MIN_CPU_CORES)."
    return 1
  fi
  log "CPU check OK: $cores cores."
  return 0
}

check_network() {
  if ! ping -c 1 google.com &>/dev/null; then
    err "No internet connectivity."
    return 1
  fi
  log "Network check OK."
  return 0
}

check_docker_health() {
  if ! command -v docker &>/dev/null; then
    err "Docker not installed or not in PATH."
    return 1
  fi
  if ! docker ps &>/dev/null; then
    err "Docker daemon not running."
    return 1
  fi
  log "Docker is healthy (daemon running)."
  return 0
}

check_service_status() {
  local service="n8n"
  if command -v systemctl &>/dev/null; then
    if ! systemctl is-active --quiet "$service"; then
      warn "Service $service is not active."
      # Return 1 if you want this to be fatal:
      # return 1
      return 0
    fi
    log "Service $service is active."
  else
    warn "systemctl not found, skipping service check."
  fi
  return 0
}

check_system_health() {
  local checks=(
    "check_disk_space"
    "check_memory"
    "check_cpu"
    "check_network"
    "check_docker_health"
    "check_service_status"
  )
  for chk in "${checks[@]}"; do
    if ! $chk; then
      err "Health check failed => $chk"
      return 1
    fi
  done
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
    log "$pkg not installed. Installing..."
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

###############################################################################
# STAGE 1: SYSTEM PREPARATION
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

  if is_stage_completed "STAGE_1_COMPLETED"; then
    log "Stage 1 was previously completed. Skipping..."
    return 0
  fi

  # 1. Validate config
  validate_config || { stage_rollback "$STAGE"; return 1; }

  # 2. Health checks
  if ! $DRY_RUN; then
    if ! check_system_health; then
      stage_rollback "$STAGE"
      return 1
    fi
  else
    log "Dry run => skipping system health checks"
  fi

  # 3. OS checks (if not overridden)
  if ! $OS_OVERRIDE; then
    local os_id
    os_id="$(. /etc/os-release; echo "$ID")"
    if [ "$os_id" != "ubuntu" ]; then
      err "Detected OS=$os_id, only 'ubuntu' is supported. (Use --override-os to skip.)"
      stage_rollback "$STAGE"
      return 1
    fi
    log "OS check => ubuntu confirmed."
  else
    warn "OS override => skipping OS checks."
  fi

  # 4. APT tasks & package version checks
  if ! $DRY_RUN; then
    apt-get update || true
    local updates
    updates="$(apt list --upgradable 2>/dev/null | wc -l)"
    apt-get upgrade -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" || true
    apt-get autoremove -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" || true

    # Check & update min versions
    for pkg in "${!MIN_PACKAGE_VERSIONS[@]}"; do
      check_package_version "$pkg" "${MIN_PACKAGE_VERSIONS[$pkg]}" \
        || warn "Could not upgrade $pkg to needed version"
    done

    local updates_applied=false
    if [ "$updates" -gt 1 ]; then
      updates_applied=true
    fi

    local reboot_required
    reboot_required="$(ls /var/run/reboot-required 2>/dev/null || true)"
    if [ -n "$reboot_required" ] && [ "$updates_applied" = true ]; then
      log "Reboot required to complete updates..."
      local reboot_cmd
      if [ "$IS_ROOT" = true ]; then
        reboot_cmd="./bootstrap.sh"
      else
        reboot_cmd="sudo ./bootstrap.sh"
      fi
      log "Rebooting in 5s; rerun => $reboot_cmd"
      sleep 5
      sudo reboot
    fi

    if [ "$updates_applied" = true ]; then
      log "--- STAGE 1 Completed With Changes ---"
    else
      log "--- STAGE 1 Completed Without Changes ---"
    fi

    mark_stage_completed "STAGE_1_COMPLETED"
  else
    log "Dry run => skipping apt tasks + package version checks."
  fi
  return 0
}

###############################################################################
# STAGE 2: USER SETUP
###############################################################################
stage_2_user_setup() {
  local STAGE="STAGE_2"

  log ""
  log "--- STAGE 2: User Setup ---"

  if [ "$FORCE_STAGE" = "2" ]; then
    warn "Forcing STAGE_2 re-run..."
    sed -i '/^STAGE_2_COMPLETED$/d' "$STATUS_FILE" || true
  fi

  check_stage_dependencies "$STAGE" || return 1

  if is_stage_completed "STAGE_2_COMPLETED"; then
    log "Stage 2 completed, skipping..."
    return 0
  fi

  local username
  if $INTERACTIVE; then
    read -rp "$USER_NAME_PROMPT " username
  else
    # Just read once; can adapt to your needs if fully non-interactive
    read -rp "$USER_NAME_PROMPT " username
  fi

  if [[ ! "$username" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
    err "Invalid username => $username"
    stage_rollback "$STAGE"
    return 1
  fi

  if id -u "$username" &>/dev/null; then
    log "User $username exists."
    read -rp "Continue setup under $username? (y/N) " cont
    if [[ "$cont" != "y" && "$cont" != "Y" ]]; then
      err "Aborting."
      stage_rollback "$STAGE"
      return 1
    fi
  else
    if ! $IS_ROOT; then
      err "Must be root to create user."
      stage_rollback "$STAGE"
      return 1
    fi

    if ! $DRY_RUN; then
      adduser "$username" || { stage_rollback "$STAGE"; return 1; }
      usermod -aG sudo "$username" || { stage_rollback "$STAGE"; return 1; }
      log "User $username created + sudo group."
    else
      log "Dry run => Would create $username + add to sudo."
    fi
  fi

  store_user_in_status "$username"

  log "Before chmod =>"
  ls -ld "/home/$username" || true

  if ! $DRY_RUN; then
    chmod 711 "/home/$username" || { stage_rollback "$STAGE"; return 1; }
  else
    log "Dry run => Would chmod 711 /home/$username"
  fi

  log "After chmod =>"
  ls -ld "/home/$username" || true

  if ! sudo -n true 2>/dev/null; then
    err "sudo -n true fails, adding $username to sudo again?"
    if ! $DRY_RUN; then
      usermod -aG sudo "$username" || { stage_rollback "$STAGE"; return 1; }
    else
      log "Dry run => Would usermod -aG sudo $username"
    fi
  fi

  log "Setting default vim colorscheme => $VIM_COLORSCHEME"
  if ! $DRY_RUN; then
    {
      echo "set background=dark"
      echo "colorscheme $VIM_COLORSCHEME"
    } | sudo tee /etc/vim/vimrc.local >/dev/null
  else
    log "Dry run => skip setting /etc/vim/vimrc.local"
  fi

  log "Setting user .vimrc => $VIM_COLORSCHEME"
  if ! $DRY_RUN; then
    echo "colorscheme $VIM_COLORSCHEME" | sudo -u "$username" tee "/home/$username/.vimrc" >/dev/null
  else
    log "Dry run => skip setting .vimrc for $username"
  fi

  mark_stage_completed "STAGE_2_COMPLETED"
  return 0
}

###############################################################################
# STAGE 3: CLONE REPOSITORY
###############################################################################
stage_3_clone_repository() {
  local STAGE="STAGE_3"

  log ""
  log "--- STAGE 3: Clone the Repository ---"

  if [ "$FORCE_STAGE" = "3" ]; then
    warn "Forcing STAGE_3 re-run..."
    sed -i '/^STAGE_3_COMPLETED$/d' "$STATUS_FILE" || true
  fi

  check_stage_dependencies "$STAGE" || return 1

  if is_stage_completed "STAGE_3_COMPLETED"; then
    log "Stage 3 done. Skipping..."
    return 0
  fi

  local boot_user
  boot_user="$(read_user_from_status)"
  if [ -z "$boot_user" ]; then
    err "No user in status => stage2 incomplete?"
    stage_rollback "$STAGE"
    return 1
  fi

  if [ ! -d "/home/$boot_user" ]; then
    err "Home directory /home/$boot_user missing => Stage2 incomplete?"
    stage_rollback "$STAGE"
    return 1
  fi

  if [ -d "/home/$boot_user/$REPO_DIR" ]; then
    log "Repo /home/$boot_user/$REPO_DIR already exists."
    if ! $DRY_RUN; then
      sudo chown -R "$boot_user":"$boot_user" "/home/$boot_user/$REPO_DIR" \
        || { stage_rollback "$STAGE"; return 1; }
    else
      log "Dry run => skip chown"
    fi
  else
    if ! $DRY_RUN; then
      sudo -u "$boot_user" mkdir -p "/home/$boot_user"
      sudo -u "$boot_user" git clone "$REPO_URL" "/home/$boot_user/$REPO_DIR" \
        || { stage_rollback "$STAGE"; return 1; }
    else
      log "Dry run => would clone $REPO_URL => /home/$boot_user/$REPO_DIR"
    fi
  fi

  log "Before chmod =>"
  ls -ld "/home/$boot_user/$REPO_DIR" || true
  if ! $DRY_RUN; then
    sudo chmod -R u+rwx "/home/$boot_user/$REPO_DIR" \
      || { stage_rollback "$STAGE"; return 1; }
  else
    log "Dry run => skip chmod"
  fi
  ls -ld "/home/$boot_user/$REPO_DIR" || true

  mark_stage_completed "STAGE_3_COMPLETED"
  return 0
}

###############################################################################
# STAGE 4: CONFIGURE & DEPLOY
###############################################################################
stage_4_configure_and_deploy() {
  local STAGE="STAGE_4"

  log ""
  log "--- STAGE 4: Configure and Deploy ---"

  if [ "$FORCE_STAGE" = "4" ]; then
    warn "Forcing STAGE_4 re-run..."
    sed -i '/^STAGE_4_COMPLETED$/d' "$STATUS_FILE" || true
  fi

  check_stage_dependencies "$STAGE" || return 1

  if is_stage_completed "STAGE_4_COMPLETED"; then
    log "Stage 4 done. Skipping..."
    return 0
  fi

  local boot_user
  boot_user="$(read_user_from_status)"
  if [ -z "$boot_user" ]; then
    err "No user found => Stage2 incomplete?"
    stage_rollback "$STAGE"
    return 1
  fi

  log "Switching to $boot_user for final script calls..."

  if ! $DRY_RUN; then
    sudo -u "$boot_user" bash << 'EOS'
      set -e

      verify_command() {
        if [ "$1" -ne 0 ]; then
          echo "[ERR] Verification failed => stage: $2"
          exit 1
        else
          echo "[LOG] Verification passed => $2"
        fi
      }

      echo "[LOG] cd => n8n_quick_setup"
      cd "n8n_quick_setup"

      echo "[LOG] chmod +x scripts/*.sh"
      chmod +x scripts/*.sh || verify_command $? "chmod scripts"

      echo "[LOG] Running final setup scripts..."
      ./scripts/setup-user.sh "$USER" || verify_command $? "setup-user"
      ./scripts/setup-fail2ban.sh || verify_command $? "setup-fail2ban"
      ./scripts/setup-ufw.sh || verify_command $? "setup-ufw"
      ./scripts/setup-docker.sh "$USER" || verify_command $? "setup-docker"

      echo "[LOG] Stage4 => Deployment done. Check README next."
EOS
  else
    log "Dry run => skip final script calls."
  fi

  mark_stage_completed "STAGE_4_COMPLETED"
  log "Stage 4 Completed!"
  log "All stages completed!"
  return 0
}

###############################################################################
# MAIN EXECUTION
###############################################################################
usage() {
  cat <<EOF
Usage: $0 [OPTIONS]

Options:
  --override-os         Skip OS checks (dangerous).
  --force-stage1..4     Re-run a specific stage even if marked completed.
  --verbose             More verbose logs (placeholder).
  --dry-run             Simulate script execution without making changes.
  --interactive         Prompt for user input more actively.
  --help, -h            Show this usage info.
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
    --force-stage1|--force-stage2|--force-stage3|--force-stage4)
      FORCE_STAGE="${1//[!0-9]/}"
      ;;
    --verbose)
      VERBOSE=true
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

# Root or sudo check
if [ "$(id -u)" -ne 0 ]; then
  if ! sudo -n true 2>/dev/null; then
    err "Need root/sudo. Rerun with sudo."
    exit 1
  else
    log "Non-root user w/ sudo."
    IS_ROOT=false
  fi
else
  log "Running as root user."
  IS_ROOT=true
fi

touch "$STATUS_FILE"
touch "$LOG_FILE"

# Execute Stages
stage_1_system_preparation
stage_2_user_setup
stage_3_clone_repository
stage_4_configure_and_deploy

log "=== n8n Quick Setup Bootstrap COMPLETE ==="
exit 0
