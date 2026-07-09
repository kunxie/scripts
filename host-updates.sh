#!/usr/bin/env bash

# Stop if an unset variable is used.
set -u

# If a command pipeline fails, treat the whole pipeline as failed.
set -o pipefail

# Cron starts with a small PATH. Include the common package-manager locations so
# the script behaves the same from cron and an interactive shell.
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

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

# Return success if a cask may need administrator privileges to upgrade.
brew_cask_needs_privileges() {
  local cask="$1"
  local cask_info

  if ! command_exists ruby; then
    return 0
  fi

  if ! cask_info="$(brew info --json=v2 --cask "${cask}")"; then
    return 0
  fi

  ruby -rjson -e '
    data = JSON.parse(STDIN.read)
    privileged_path = %r{\A/(Library/(LaunchDaemons|PrivilegedHelperTools)|System/)}

    needs_privileges = lambda do |value|
      case value
      when Hash
        return true if value.key?("pkg") || value.key?("installer")
        return true if value.key?("launchctl") || value.key?("kext")

        value.any? do |key, nested|
          key == "target" && nested.is_a?(String) && nested.match?(privileged_path) ||
            needs_privileges.call(nested)
        end
      when Array
        value.any? { |nested| needs_privileges.call(nested) }
      when String
        value.match?(privileged_path)
      else
        false
      end
    end

    exit(data.fetch("casks", []).any? { |cask| needs_privileges.call(cask.fetch("artifacts", [])) } ? 0 : 1)
  ' <<< "${cask_info}"
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

# Run a command with retries, then remember one failure if all attempts fail.
run_with_retries() {
  local attempts="$1"
  local delay_seconds="$2"
  shift 2

  local attempt=1
  local status=0

  while [ "${attempt}" -le "${attempts}" ]; do
    log "Running attempt ${attempt}/${attempts}: $*"
    if "$@"; then
      log "Completed: $*"
      return
    fi

    status=$?
    if [ "${attempt}" -lt "${attempts}" ]; then
      log "Attempt ${attempt}/${attempts} failed (${status}); retrying in ${delay_seconds}s: $*"
      sleep "${delay_seconds}"
    fi

    attempt=$((attempt + 1))
  done

  log "Failed after ${attempts} attempts (${status}): $*"
  FAILURES=$((FAILURES + 1))
}

# Return success when this script can run apt commands without prompting.
can_run_apt() {
  if [ "$(id -u)" -eq 0 ]; then
    return 0
  fi

  command_exists sudo && sudo -n true >/dev/null 2>&1
}

# Update Ubuntu/Debian packages through apt-get.
run_apt() {
  if ! command_exists apt-get; then
    log "apt-get is not installed; skipping apt updates."
    return
  fi

  if ! can_run_apt; then
    log "apt updates require root or passwordless sudo; skipping apt updates."
    FAILURES=$((FAILURES + 1))
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

  local apt_prefix=()
  if [ "$(id -u)" -ne 0 ]; then
    apt_prefix=(sudo -n)
  fi

  run "${apt_prefix[@]}" "${apt_env[@]}" apt-get update
  run "${apt_prefix[@]}" "${apt_env[@]}" apt-get upgrade -y "${apt_options[@]}"

  # autoremove deletes packages that were installed as dependencies but are no
  # longer needed.
  run "${apt_prefix[@]}" "${apt_env[@]}" apt-get autoremove -y

  # clean removes downloaded package files from apt's local cache.
  run "${apt_prefix[@]}" "${apt_env[@]}" apt-get clean
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

  # Formula upgrades do not require cask helper removal/install steps.
  run "${brew_env[@]}" brew upgrade --formula

  # Upgrade casks one at a time so privileged casks can be skipped.
  local outdated_casks
  local skipped_privileged_casks=()
  outdated_casks="$("${brew_env[@]}" brew outdated --cask --greedy --quiet 2>/dev/null || true)"

  if [ -z "${outdated_casks}" ]; then
    log "No outdated Homebrew casks found."
  else
    local cask
    while IFS= read -r cask; do
      [ -n "${cask}" ] || continue

      if brew_cask_needs_privileges "${cask}"; then
        log "Skipping privileged Homebrew cask: ${cask}"
        skipped_privileged_casks+=("${cask}")
      else
        run "${brew_env[@]}" brew upgrade --cask --greedy "${cask}"
      fi
    done <<< "${outdated_casks}"

    if [ "${#skipped_privileged_casks[@]}" -gt 0 ]; then
      log "Privileged Homebrew casks not updated:"
      for cask in "${skipped_privileged_casks[@]}"; do
        log "  - ${cask}"
      done
    fi
  fi

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

  # Keep each tool within the version range set in mise config.
  run_with_retries 3 30 mise upgrade --yes

  # prune removes old mise-managed tool versions that are no longer used.
  run mise prune --yes
}

main() {
  log "Starting host updates. Log file: ${LOG_FILE}"

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
