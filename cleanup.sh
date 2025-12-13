#!/usr/bin/env bash
#
# Robust Linux Cleanup Script (Upgraded)
# - Safer defaults (dry-run + interactive confirmation where destructive)
# - Better logging + summary
# - Detects package manager (apt/dnf/yum/pacman/zypper)
# - Docker/Podman support
# - Avoids buggy error counting and dangerous system-wide deletes by default
#
# USAGE:
#   sudo ./cleanup.sh                  # interactive
#   sudo ./cleanup.sh --yes            # assume yes (dangerous)
#   sudo ./cleanup.sh --dry-run        # show what would be deleted/pruned
#   sudo ./cleanup.sh --vacuum 2d      # journal vacuum time
#   sudo ./cleanup.sh --logs-size 5M   # delete logs larger than this
#   sudo ./cleanup.sh --big-size 10M   # (optional) big file threshold
#   sudo ./cleanup.sh --enable-big-delete  # allow system-wide big-file deletion
#
set -euo pipefail
IFS=$'\n\t'

# ------------------------- Defaults / Config -------------------------
LOG_DIRS=(/var/log /var/logs)
LARGE_LOG_SIZE="5M"      # find -size expects no leading '+', we add it
LARGE_FILE_SIZE="10M"    # same
JOURNAL_VACUUM_TIME="2d"

DRY_RUN=0
ASSUME_YES=0
ENABLE_BIG_DELETE=0

# Extensions cleaned in big-delete step
BIG_DELETE_EXTENSIONS=(zip tar gz log bak)

# ------------------------- Output helpers --------------------------
if [[ -t 1 ]]; then
  RED=$'\033[0;31m'
  GREEN=$'\033[0;32m'
  YELLOW=$'\033[1;33m'
  BLUE=$'\033[0;34m'
  NC=$'\033[0m'
else
  RED=""; GREEN=""; YELLOW=""; BLUE=""; NC=""
fi

log_info()    { printf '%s[INFO]%s %s\n'    "$BLUE"  "$NC" "$*"; }
log_success() { printf '%s[SUCCESS]%s %s\n' "$GREEN" "$NC" "$*"; }
log_warning() { printf '%s[WARNING]%s %s\n' "$YELLOW" "$NC" "$*"; }
log_error()   { printf '%s[ERROR]%s %s\n'   "$RED"   "$NC" "$*"; }

die() { log_error "$*"; exit 1; }

# ------------------------- State / Summary --------------------------
START_TS="$(date +%s)"
DELETED_LOG_FILES=0
TRUNCATED_DOCKER_LOGS=0
BIG_FILES_DELETED=0
PKG_CLEANED=0
SNAPS_REMOVED=0

# ------------------------- CLI parsing -----------------------------
usage() {
  cat <<'EOF'
cleanup.sh - robust linux cleanup

Options:
  --dry-run                 Show actions without deleting/pruning
  --yes                     Assume "yes" to prompts (dangerous)
  --enable-big-delete        Enable system-wide large file deletion step
  --vacuum <time>           journalctl vacuum time (default: 2d)
  --logs-size <size>        delete logs larger than this (default: 5M)
  --big-size <size>         big file threshold (default: 10M)
  -h, --help                show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --yes) ASSUME_YES=1; shift ;;
    --enable-big-delete) ENABLE_BIG_DELETE=1; shift ;;
    --vacuum) JOURNAL_VACUUM_TIME="${2:-}"; shift 2 ;;
    --logs-size) LARGE_LOG_SIZE="${2:-}"; shift 2 ;;
    --big-size) LARGE_FILE_SIZE="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1 (try --help)" ;;
  esac
done

# ------------------------- Safety checks ---------------------------
check_root() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || die "Must run as root (use sudo)."
}

command_exists() { command -v "$1" >/dev/null 2>&1; }

confirm() {
  local prompt="$1"
  if [[ "$ASSUME_YES" -eq 1 ]]; then
    return 0
  fi
  read -r -p "${prompt} (y/N): " response || true
  case "${response:-}" in
    [yY]|[yY][eE][sS]) return 0 ;;
    *) return 1 ;;
  esac
}

run() {
  # run <command...>
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log_info "[dry-run] $*"
    return 0
  fi
  "$@"
}

# ------------------------- Helpers --------------------------------
disk_report() {
  log_info "Disk usage:"
  df -h / || true
}

detect_pkg_manager() {
  if command_exists apt-get; then echo "apt"; return; fi
  if command_exists dnf; then echo "dnf"; return; fi
  if command_exists yum; then echo "yum"; return; fi
  if command_exists pacman; then echo "pacman"; return; fi
  if command_exists zypper; then echo "zypper"; return; fi
  echo "none"
}

container_engine() {
  if command_exists docker; then echo "docker"; return; fi
  if command_exists podman; then echo "podman"; return; fi
  echo "none"
}

# ------------------------- Steps -----------------------------------
cleanup_containers() {
  local engine; engine="$(container_engine)"
  log_info "Step 1: Container cleanup..."
  case "$engine" in
    docker)
      run docker system prune -a -f --volumes
      run docker builder prune -a -f

      # Truncate container JSON logs (safe-ish; doesn't delete files)
      if [[ -d /var/lib/docker/containers ]]; then
        log_info "Truncating large Docker container logs..."
        if [[ "$DRY_RUN" -eq 1 ]]; then
          find /var/lib/docker/containers -type f -name "*.log" -size "+${LARGE_LOG_SIZE}" -print 2>/dev/null | sed 's/^/[dry-run] would truncate /' || true
        else
          while IFS= read -r f; do
            truncate -s 0 "$f" || true
            TRUNCATED_DOCKER_LOGS=$((TRUNCATED_DOCKER_LOGS + 1))
          done < <(find /var/lib/docker/containers -type f -name "*.log" -size "+${LARGE_LOG_SIZE}" -print 2>/dev/null)
        fi
      fi
      log_success "Docker cleanup complete."
      ;;
    podman)
      run podman system prune -a -f
      log_success "Podman cleanup complete."
      ;;
    *)
      log_warning "No Docker/Podman found. Skipping container cleanup."
      ;;
  esac
}

cleanup_journal() {
  log_info "Step 2: Journald cleanup (vacuum ${JOURNAL_VACUUM_TIME})..."
  if command_exists journalctl; then
    run journalctl --vacuum-time="${JOURNAL_VACUUM_TIME}"
    log_success "Journal cleaned."
  else
    log_warning "journalctl not found. Skipping journald cleanup."
  fi
}

cleanup_logs() {
  log_info "Step 3: Deleting log files > ${LARGE_LOG_SIZE} in: ${LOG_DIRS[*]}"
  local dir
  for dir in "${LOG_DIRS[@]}"; do
    [[ -d "$dir" ]] || continue

    if [[ "$DRY_RUN" -eq 1 ]]; then
      find "$dir" -type f -size "+${LARGE_LOG_SIZE}" -print 2>/dev/null \
        | sed "s|^|[dry-run] would delete |" || true
      continue
    fi

    # Count deletions robustly
    while IFS= read -r f; do
      rm -f -- "$f" || true
      DELETED_LOG_FILES=$((DELETED_LOG_FILES + 1))
    done < <(find "$dir" -type f -size "+${LARGE_LOG_SIZE}" -print 2>/dev/null)
  done
  log_success "Log cleanup complete."
}

big_system_delete() {
  log_info "Step 4: Optional system-wide large file deletion..."

  if [[ "$ENABLE_BIG_DELETE" -ne 1 ]]; then
    log_warning "Big-delete step is DISABLED by default."
    log_info "To enable: re-run with --enable-big-delete (and consider --dry-run first)."
    return 0
  fi

  log_warning "This can delete user/application data if you are not careful."
  log_warning "Scope: / (same filesystem only via -xdev), extensions: ${BIG_DELETE_EXTENSIONS[*]}, size > ${LARGE_FILE_SIZE}"

  if ! confirm "Proceed with system-wide deletion"; then
    log_info "Skipping big-delete step."
    return 0
  fi

  # build find expression for extensions
  local expr=()
  local ext
  for ext in "${BIG_DELETE_EXTENSIONS[@]}"; do
    expr+=( -iname "*.${ext}" -o )
  done
  unset 'expr[${#expr[@]}-1]' 2>/dev/null || true # drop trailing -o

  if [[ "$DRY_RUN" -eq 1 ]]; then
    # shellcheck disable=SC2016
    find / -xdev -type f \( "${expr[@]}" \) -size "+${LARGE_FILE_SIZE}" -print 2>/dev/null \
      | sed 's/^/[dry-run] would delete /' || true
  else
    while IFS= read -r f; do
      rm -f -- "$f" || true
      BIG_FILES_DELETED=$((BIG_FILES_DELETED + 1))
    done < <(find / -xdev -type f \( "${expr[@]}" \) -size "+${LARGE_FILE_SIZE}" -print 2>/dev/null)
  fi

  log_success "Big-delete step complete."
}

cleanup_packages() {
  log_info "Step 5: Package manager cleanup..."
  local pm; pm="$(detect_pkg_manager)"
  case "$pm" in
    apt)
      run apt-get autoremove -y
      run apt-get clean
      run rm -rf /var/cache/apt/archives/* || true
      PKG_CLEANED=1
      log_success "APT cleanup complete."
      ;;
    dnf)
      run dnf autoremove -y || true
      run dnf clean all
      PKG_CLEANED=1
      log_success "DNF cleanup complete."
      ;;
    yum)
      run yum autoremove -y || true
      run yum clean all
      PKG_CLEANED=1
      log_success "YUM cleanup complete."
      ;;
    pacman)
      # remove unneeded packages + clear cache (keeps last 3 versions by default if paccache exists)
      if command_exists paccache; then
        run paccache -r
      else
        log_warning "paccache not found; skipping cache trimming."
      fi
      run pacman -Sc --noconfirm || true
      PKG_CLEANED=1
      log_success "Pacman cleanup complete."
      ;;
    zypper)
      run zypper clean -a
      PKG_CLEANED=1
      log_success "Zypper cleanup complete."
      ;;
    *)
      log_warning "No supported package manager found. Skipping package cleanup."
      ;;
  esac
}

cleanup_snaps() {
  log_info "Step 6: Snap old revisions cleanup..."
  if ! command_exists snap; then
    log_info "snap not found. Skipping."
    return 0
  fi

  # Remove disabled revisions
  if [[ "$DRY_RUN" -eq 1 ]]; then
    snap list --all | awk '/disabled/{print "[dry-run] would remove snap:", $1, "rev", $3}'
    return 0
  fi

  while read -r snapname revision; do
    [[ -n "${snapname:-}" && -n "${revision:-}" ]] || continue
    log_info "Removing old Snap: ${snapname} (rev ${revision})"
    snap remove "$snapname" --revision="$revision" || true
    SNAPS_REMOVED=$((SNAPS_REMOVED + 1))
  done < <(snap list --all | awk '/disabled/{print $1, $3}')

  log_success "Snap cleanup complete."
}

# ------------------------- Main ------------------------------------
check_root

echo
log_info "=== Starting System Cleanup ==="
[[ "$DRY_RUN" -eq 1 ]] && log_warning "Running in DRY-RUN mode (no changes will be made)."
disk_report
echo

cleanup_containers
cleanup_journal
cleanup_logs
big_system_delete
cleanup_packages
cleanup_snaps

echo
log_success "=== Cleanup Completed ==="
disk_report

END_TS="$(date +%s)"
log_info "Summary:"
log_info "  Deleted log files:          ${DELETED_LOG_FILES}"
log_info "  Truncated container logs:   ${TRUNCATED_DOCKER_LOGS}"
log_info "  Big files deleted:          ${BIG_FILES_DELETED}"
log_info "  Package cleanup performed:  ${PKG_CLEANED}"
log_info "  Snap revisions removed:     ${SNAPS_REMOVED}"
log_info "  Elapsed seconds:            $((END_TS - START_TS))"

log_warning "Note: Some disk space may remain 'in use' until services restart (e.g., processes holding deleted files open)."
