#!/bin/bash

echo "=== Starting Full Cleanup ==="

# Show disk usage before cleanup
echo -e "\n[*] Disk usage BEFORE cleanup:"
df -h /

# Step 1: Docker Cleanup
echo -e "\n[*] Cleaning up Docker (containers, images, volumes)..."
docker system prune -a -f --volumes

# Step 2: Docker build cache prune
echo "[*] Pruning Docker build cache..."
docker builder prune -a -f

# Step 3: Journal logs cleanup (if systemd)
echo "[*] Cleaning journal logs older than 2 days..."
journalctl --vacuum-time=2d

# Step 4: Delete large log files in /var/log and /var/logs
echo "[*] Deleting log files over 5MB in /var/log and /var/logs..."
for dir in /var/log /var/logs; do
  if [ -d "$dir" ]; then
    find "$dir" -type f -size +5M -exec rm -f {} \;
  fi
done

# Step 5: Delete big unused files (zip, tar, gz, log, bak) over 10MB
echo "[*] Deleting files >10MB across the system..."
find / -xdev -type f \( -iname "*.zip" -o -iname "*.tar" -o -iname "*.gz" -o -iname "*.log" -o -iname "*.bak" \) -size +10M -exec rm -f {} \; 2>/dev/null

# Step 6: Clear APT package cache and unused packages
echo "[*] Cleaning up APT..."
apt autoremove -y
apt clean
rm -rf /var/cache/apt/archives/*

# Step 7: Optional Snap cleanup (uncomment if you use Snap)
# echo "[*] Cleaning old Snap revisions..."
# snap list --all | awk '/disabled/{print $1, $2}' | while read snapname version; do
#   snap remove "$snapname" --revision="$version"
# done

# Step 8: Truncate large Docker container logs
echo "[*] Truncating large Docker container logs..."
find /var/lib/docker/containers/ -type f -name "*.log" -exec truncate -s 0 {} \; 2>/dev/null

# Show disk usage after cleanup
echo -e "\n[*] Disk usage AFTER cleanup:"
df -h /

echo -e "\n=== Cleanup Completed ==="
