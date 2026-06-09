# Immich Backup Script (Duplicacy + PostgreSQL Dump)

This repository provides a comprehensive Bash script to automate the backup of an [Immich](https://immich.app/) instance. It is specifically designed to work seamlessly with Docker Compose and [Duplicacy CLI (free)](https://github.com/gilbertchen/duplicacy/releases), ensuring both your photos and your PostgreSQL database are safely backed up with minimal downtime.

While the script includes native notifications for [Unraid](https://unraid.net), it can be easily adapted for any Linux-based environment.

## ✨ Features

* **Graceful Service Handling:** Stops application containers (server, machine learning, redis) to prevent file locks, while keeping the database container running for a clean dump.
* **Database Dump:** Automatically generates a compressed PostgreSQL dump (`pg_dumpall`).
* **Duplicacy Integration:** Backs up the entire Immich data directory (including the fresh DB dump) using Duplicacy.
* **Automated Retention:** Applies a 30-day prune policy to save storage space.
* **Health Checks:** Restarts the Docker stack and waits for the Immich API to report a healthy status before finishing.
* **Smart Notifications:** Sends Unraid webGUI notifications immediately on error, or weekly on Mondays for successful backups.
* **Log Management:** Generates local logs and copies them to your remote backup destination.

## 📋 Prerequisites

Before running this script, ensure you have the following installed and configured:

1. **Docker & Docker Compose**
2. **Duplicacy CLI:** Installed and accessible.
3. **Initialized Repository:** Your Immich data directory must already be initialized as a Duplicacy repository (`duplicacy init`).
4. *(Optional)* **Unraid:** For the native notification system to work out of the box.

## ⚙️ Configuration

Open the script and adjust the variables in the **CONFIGURATION** sections to match your environment:

* `SOURCE_PATH`: The main directory where your Immich data is stored.
* `DUPLICACY_BIN`: Path to your Duplicacy executable.
* `COMPOSE_FILE`: Absolute path to your Immich `docker-compose.yml`.
* `FREEBOX_LOG_DIR` (or generic remote path): The mounted destination path where you want to store a copy of the backup logs.

## ✂️ Excluding Generated Files (Filters)

To save storage space and reduce backup time, it is highly recommended to exclude dynamically generated files like thumbnails and transcoded videos. Immich can automatically regenerate these files if they are missing after a restore.

You can exclude these folders using Duplicacy's filtering system. Create or edit the `filters` file located inside your initialized `.duplicacy` directory (for example, `/mnt/data/xxx/immich/.duplicacy/filters`).

Add the following lines to the file:

```text
-thumbs/
-encoded-video/
+*

```

**How it works:**

* `-thumbs/`: Ignores the folder containing generated image thumbnails.
* `-encoded-video/`: Ignores the folder containing transcoded, web-friendly videos.
* `+*`: Explicitly includes all other files and folders in your Immich directory (such as your original uploads and the database dump).

## 🚀 Usage

Make the script executable:

```bash
chmod +x backup_immich.sh

```

Run the script manually or set it up in your preferred scheduler (e.g., cron or Unraid's User Scripts plugin):

```bash
./backup_immich.sh

```

---

## ♻️ How to Restore Immich

If you need to perform a full restore from your backup destination, follow these steps:

1. **Navigate to the target directory**
On your server (e.g., Unraid), go to the directory where the Immich data should be restored:
```bash
cd /mnt/data/xxx/immich

```


2. **Initialize Duplicacy**
Initialize Duplicacy in this directory, pointing it to your remote backup storage:
```bash
duplicacy init duplicacy_immich /mnt/remotes/FREEBOX-SERVER_Freebox/backup_immich/

```


3. **Check available versions**
List all available backup snapshots to find the one you want to restore:
```bash
duplicacy list

```


4. **Restore the data**
Restore the highest/latest version (replace `<version_number>` with the actual revision number):
```bash
duplicacy restore -r <version_number> -overwrite -stats

```


5. **Start the Docker stack**
Once the files are restored, bring your containers back up:
```bash
docker compose up -d

```


6. **Restore the Database via UI**
Access your Immich web interface. Because the database dump is present in the restored files, Immich will automatically detect it and prompt you to restore the database directly from the login screen.
7. **Re-enable Backups**
Don't forget to re-enable your backup scheduler or cron job so future backups continue running!
