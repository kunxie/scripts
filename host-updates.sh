#!/usr/bin/env bash

# Stop if an unset variable is used.
set -u

# If a command pipeline fails, treat the whole pipeline as failed.
set -o pipefail

# Every run writes to a fresh log file under $HOME/logs.
LOG_DIR="${HOME}/logs"
TIMESTAMP="$(date '+%Y%m%d-%H%M%S')"
LOG_FILE="${LOG_DIR}/host-updates-${TIMESTAMP}.log"

# Count failed update commands. The script exits with this number at the end.
FAILURES=0

# Create the log directory if it does not already exist.
mkdir -p "${LOG_DIR}"

# Delete old logs from this script that are more than 7 days old.
find "${LOG_DIR}" -name 'host-updates-*.log' -type f -mtime +7 -delete

# Send all normal output and error output to both the terminal and the log file.
exec > >(tee -a "${LOG_FILE}") 2>&1

# Print a message with a readable timestamp.
log() {
  printf '\n[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

# Return success if a command exists in PATH.
# Example: command_exists brew
command_exists() {
  command -v "$1" >/dev/null 2>&1
}

# Run a command, log it, and remember failures without stopping the script.
# "$@" means "all arguments passed to this function, exactly as separate words".
run() {
  log "Running: $*"
  if "$@"; then
    log "Completed: $*"
  else
    local status=$?
    log "Failed (${status}): $*"
    FAILURES=$((FAILURES + 1))
  fi
}

# Return success when this script should use sudo for apt commands.
# If already running as root, sudo is not needed.
sudo_prefix() {
  if [ "$(id -u)" -eq 0 ]; then
    return 1
  fi

  command_exists sudo
}

# Update Ubuntu/Debian packages through apt-get.
run_apt() {
  if ! command_exists apt-get; then
    log "apt-get is not installed; skipping apt updates."
    return
  fi

  # These environment variables reduce or avoid interactive prompts.
  local apt_env
  apt_env=(
    env
    DEBIAN_FRONTEND=noninteractive
    NEEDRESTART_MODE=a
    APT_LISTCHANGES_FRONTEND=none
  )

  # Keep existing config files automatically when package upgrades ask.
  local apt_options
  apt_options=(
    -o Dpkg::Options::=--force-confdef
    -o Dpkg::Options::=--force-confold
  )

  # Use sudo when available and needed. Otherwise run apt-get directly.
  if sudo_prefix; then
    run sudo "${apt_env[@]}" apt-get update -y
    run sudo "${apt_env[@]}" apt-get upgrade -y "${apt_options[@]}"
    run sudo "${apt_env[@]}" apt-get autoremove -y
  else
    run "${apt_env[@]}" apt-get update -y
    run "${apt_env[@]}" apt-get upgrade -y "${apt_options[@]}"
    run "${apt_env[@]}" apt-get autoremove -y
  fi
}

# Update Homebrew packages on macOS.
run_brew() {
  if ! command_exists brew; then
    log "Homebrew is not installed; skipping brew updates."
    return
  fi

  # These environment variables make Homebrew quieter and noninteractive.
  local brew_env
  brew_env=(
    env
    HOMEBREW_NO_ANALYTICS=1
    HOMEBREW_NO_ENV_HINTS=1
    NONINTERACTIVE=1
  )

  # update refreshes Homebrew itself and formula metadata.
  run "${brew_env[@]}" brew update

  # upgrade --greedy also upgrades casks that normally require extra prompting.
  run "${brew_env[@]}" brew upgrade --greedy

  # cleanup removes old downloaded files and old package versions.
  run "${brew_env[@]}" brew cleanup
}

# Return success if the mise executable belongs to an apt package.
# On Linux, apt-managed mise should be upgraded by apt, not by mise self-update.
mise_managed_by_apt() {
  if ! command_exists dpkg-query; then
    return 1
  fi

  local mise_path
  mise_path="$(command -v mise 2>/dev/null || true)"
  [ -n "${mise_path}" ] && dpkg-query -S "${mise_path}" >/dev/null 2>&1
}

# Update mise itself when appropriate, then upgrade tools installed by mise.
run_mise() {
  if ! command_exists mise; then
    log "mise is not installed; skipping mise updates."
    return
  fi

  # On Linux only: self-update mise when it is not installed through apt.
  if [ "$(uname -s)" = "Linux" ] && ! mise_managed_by_apt; then
    run mise self-update --yes
  fi

  # --bump moves configured tools to the newest available versions.
  run mise upgrade --yes --bump
}

main() {
  log "Starting daily updates. Log file: ${LOG_FILE}"

  # Choose the update path based on the operating system name.
  case "$(uname -s)" in
    Darwin)
      run_brew
      run_mise
      ;;
    Linux)
      # This script is written for Ubuntu-like Linux systems, but still works
      # anywhere apt-get is installed.
      if [ -r /etc/os-release ] && ! grep -qi '^ID=.*ubuntu\|^ID_LIKE=.*ubuntu' /etc/os-release; then
        log "Linux distribution is not Ubuntu-like; apt updates will run only if apt-get exists."
      fi
      run_apt
      run_mise
      ;;
    *)
      log "Unsupported OS: $(uname -s)"
      FAILURES=$((FAILURES + 1))
      ;;
  esac

  # Report the final result and exit with 0 for success or nonzero for failure.
  if [ "${FAILURES}" -eq 0 ]; then
    log "Host updates completed successfully."
  else
    log "Host updates completed with ${FAILURES} failure(s)."
  fi

  exit "${FAILURES}"
}

# Start the script.
main "$@"
