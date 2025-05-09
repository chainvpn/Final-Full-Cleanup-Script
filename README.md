# Ubuntu Server Cleanup Script

A one-command bash script to free up disk space on Ubuntu servers by cleaning:

- Unused Docker containers, images, and volumes
- Docker build cache
- Systemd journal logs
- Large log files in `/var/log`
- Unused `.zip`, `.tar`, `.gz`, `.log`, and `.bak` files over 10MB
- APT package cache and unused packages
- (Optional) Old Snap package revisions
- Large Docker container logs

Perfect for minimal servers running Docker on limited storage (e.g. 10GB).

---

## 💡 Features

- Safe cleanup using `docker system prune`, `apt autoremove`, and more
- Deletes files intelligently based on size and type
- Displays disk usage **before and after** cleanup
- Optional Snap package cleanup
- Truncates Docker container log files without removing containers

---

## 🛠️ Usage

### 1. Clone this repository or download the script:

```bash
git clone https://github.com/your-username/ubuntu-cleanup-script.git
cd ubuntu-cleanup-script
