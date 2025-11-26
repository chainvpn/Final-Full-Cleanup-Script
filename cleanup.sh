#!/bin/bash
#
# Robust Linux Cleanup Script
# Optimizes disk space by removing caches, old logs, and unused packages/containers.
#
# USAGE: sudo ./cleanup.sh

set -euo pipefail # Exit on error, unset variables, and pipe failure

# --- Configuration ---
LOG_DIR="/var/log"
LOG_DIRS="/var/log /var/logs" # Include /var/logs just in case
LARGE_LOG_SIZE="+5M"
LARGE_FILE_SIZE="+10M"
JOURNAL_VACUUM_TIME="2d"

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# --- Functions ---

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root (use 'sudo')."
        exit 1
    fi
}

confirm_deletion() {
    log_warning "ATTENTION: This step deletes files larger than ${LARGE_FILE_SIZE} across your system."
    read -r -p "Do you want to proceed with system-wide file deletion? (y/N): " response
    case "$response" in
        [yY][eE][sS]|[yY])
            return 0 # Proceed
            ;;
        *)
            log_info "Skipping system-wide file deletion step."
            return 1 # Skip
            ;;
    esac
}

# --- Main Script ---

check_root

echo -e "\n=== 🧹 Starting Robust System Cleanup ===\n"

# Show disk usage before cleanup
log_info "Disk usage BEFORE cleanup:"
df -h /

# --- Step 1: Docker Cleanup ---
log_info "Step 1: Cleaning up Docker (containers, images, volumes)..."
if command -v docker &> /dev/null; then
    docker system prune -a -f --volumes 2>&1
    log_success "Docker system pruned."
    
    log_info "Pruning Docker build cache..."
    docker builder prune -a -f 2>&1
    log_success "Docker build cache pruned."
    
    log_info "Truncating large Docker container logs..."
    find /var/lib/docker/containers/ -type f -name "*.log" -exec truncate -s 0 {} \; 2>/dev/null
    log_success "Docker container logs truncated."
else
    log_warning "Docker command not found. Skipping Docker cleanup."
fi

# --- Step 2: System Log Cleanup (journalctl) ---
log_info "Step 2: Cleaning journal logs older than ${JOURNAL_VACUUM_TIME}..."
if command -v journalctl &> /dev/null; then
    journalctl --vacuum-time="${JOURNAL_VACUUM_TIME}"
    log_success "Journal logs cleaned."
else
    log_warning "journalctl not found. Skipping journal cleanup."
fi

# --- Step 3: Local Log File Deletion ---
log_info "Step 3: Deleting log files over ${LARGE_LOG_SIZE} in ${LOG_DIR} directories..."
deleted_count=0
for dir in ${LOG_DIRS}; do
    if [ -d "$dir" ]; then
        # Use -delete for safer atomic deletion on the find command
        find "$dir" -type f -size ${LARGE_LOG_SIZE} -delete 2>/dev/null
        deleted_count=$((deleted_count + $?))
    fi
done
if [ "$deleted_count" -eq 0 ]; then
    log_success "Log files cleanup completed (0 errors)."
else
    log_warning "Log files cleanup completed (with potential errors during deletion)."
fi

# --- Step 4: System-Wide File Deletion (Requires Confirmation) ---
log_info "Step 4: Checking for large unused files system-wide..."
if confirm_deletion; then
    log_info "Deleting files >${LARGE_FILE_SIZE} with extensions: zip, tar, gz, log, bak..."
    # -xdev prevents crossing filesystem boundaries (e.g., /mnt or /home partitions)
    # -delete is more efficient than -exec rm -f {} \;
    find / -xdev -type f \( -iname "*.zip" -o -iname "*.tar" -o -iname "*.gz" -o -iname "*.log" -o -iname "*.bak" \) -size ${LARGE_FILE_SIZE} -delete 2>/dev/null
    log_success "System-wide file deletion finished."
fi

# --- Step 5: APT Package Cleanup ---
log_info "Step 5: Cleaning up APT package cache and unused packages..."
if command -v apt &> /dev/null; then
    apt autoremove -y 2>&1
    apt clean 2>&1
    rm -rf /var/cache/apt/archives/* 2>/dev/null
    log_success "APT cache and unused packages cleaned."
else
    log_warning "APT command not found. Skipping APT cleanup."
fi


# --- Step 6: Snap Cleanup (Conditional) ---
log_info "Step 6: Checking for old Snap revisions (if Snap is installed)..."
if command -v snap &> /dev/null; then
    snap list --all | awk '/disabled/{print $1, $3}' | while read snapname revision; do
        if [ -n "$snapname" ] && [ "$revision" != "revision" ]; then # Basic safety check
            log_info "Removing old Snap: ${snapname} (rev ${revision})"
            snap remove "$snapname" --revision="$revision" 2>&1
        fi
    done
    log_success "Snap revisions cleaned."
else
    log_info "Snap command not found. Skipping Snap cleanup."
fi

# --- Final Output ---
echo -e "\n${GREEN}=== ✨ System Cleanup Completed ===${NC}"
log_info "Disk usage AFTER cleanup:"
df -h /

log_warning "Recommendation: Some changes (like log truncations) may require a service restart or system reboot to fully free up space used by running processes."
