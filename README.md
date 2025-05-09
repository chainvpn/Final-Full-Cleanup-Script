# 🧹 Final Full Cleanup Script for Ubuntu Servers

This script helps clean up Ubuntu servers — especially minimal setups with limited storage (like 10GB) — by reclaiming disk space from:

- Unused Docker containers, images, volumes, and build cache
- Old journal logs
- Large log files in `/var/log` and `/var/logs`
- Archived and backup files (`.zip`, `.tar`, `.gz`, `.log`, `.bak`) over 10MB
- APT cache and unused packages
- (Optional) Old Snap package revisions
- Large Docker container logs

📁 Repo: [chainvpn/Final-Full-Cleanup-Script](https://github.com/chainvpn/Final-Full-Cleanup-Script)

---

## ⚡ Quick Usage (Inline)

You can run it directly on your server with:

```bash
curl -sSL https://raw.githubusercontent.com/chainvpn/Final-Full-Cleanup-Script/main/cleanup.sh | sudo bash
