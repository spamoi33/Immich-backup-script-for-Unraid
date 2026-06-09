#!/bin/bash

# ==============================================================================
# IMMICH BACKUP SCRIPT - CONTAINER STOP VERSION
# ==============================================================================
# - Stop services: docker compose stop (except DB)
# - Restart services: docker compose up -d
# - Backup: PostgreSQL Dump + Duplicacy (Files)
# - Retention: 30 days (Prune)
# ==============================================================================

set -euo pipefail

# --- 1. PATH CONFIGURATION ---
SOURCE_PATH="/mnt/data/xxx/immich"
BACKUP_NAME="backup_immich"
DUPLICACY_BIN="/usr/local/bin/duplicacy"
COMPOSE_FILE="/boot/config/plugins/compose.manager/projects/Immich/docker-compose.yml"

# --- 2. DOCKER CONFIGURATION ---
IMMICH_HEALTH_URL="http://localhost:2283/api/server/ping"
DB_CONTAINER="immich_postgres"
DB_USERNAME="postgres"
DB_DUMP_FILENAME="immich_db_dump.sql.gz"
DB_DUMP_PATH="$SOURCE_PATH/backups"

# Services to stop (keep DB running for the dump)
SERVICES_TO_STOP="immich-server immich-machine-learning redis"

# --- 3. LOGS AND LOCK PARAMETERS ---
LOG_DIR="/mnt/data/appdata/duplicacy_logs"
LOG_FILE="$LOG_DIR/${BACKUP_NAME}_$(date +%Y%m%d).log"
LOCK_FILE="/tmp/${BACKUP_NAME}.lock"
THREADS=$(nproc)

# --- ADDITION: DESTINATION PATH CONFIGURATION (FREEBOX) ---
# Replace with the actual Freebox mount path on Unraid
FREEBOX_LOG_DIR="/mnt/remotes/FREEBOX-SERVER_Freebox/backup_immich"

# --- 4. INITIALIZATION AND LOGGING ---
mkdir -p "$LOG_DIR"
mkdir -p "$DB_DUMP_PATH"
exec > >(tee -a "$LOG_FILE") 2>&1

SCRIPT_ERRORS=0

echo "================================================================"
echo "STARTING BACKUP CYCLE: $(date)"
echo "================================================================"

START_TOTAL=$(date +%s)

# Prevent multiple executions
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    echo "ERROR: A backup is already in progress. Aborting."
    exit 1
fi

# --- 5. STOP APPLICATION SERVICES ---
echo "--- STEP 1: STOP SERVICES (EXCLUDING DB) ---"
if docker compose -f "$COMPOSE_FILE" stop $SERVICES_TO_STOP; then
    echo "Services stopped successfully."
else
    echo "ERROR: Failed to stop services via Docker Compose."
    SCRIPT_ERRORS=$((SCRIPT_ERRORS + 1))
    # Continuing anyway as DB dump remains possible if it's running
fi

# --- 6. DATABASE BACKUP ---
echo "--- STEP 2: POSTGRESQL EXPORT ---"
# Check if DB container is online
if [ "$(docker inspect -f '{{.State.Running}}' "$DB_CONTAINER" 2>/dev/null)" = "true" ]; then
    if docker exec -t "$DB_CONTAINER" pg_dumpall --clean --if-exists --username="$DB_USERNAME" | gzip > "$DB_DUMP_PATH/$DB_DUMP_FILENAME"; then
        echo "Database exported successfully."
    else
        echo "WARNING: SQL dump failed."
        SCRIPT_ERRORS=$((SCRIPT_ERRORS + 1))
    fi
else
    echo "ERROR: Database container ($DB_CONTAINER) is not running."
    SCRIPT_ERRORS=$((SCRIPT_ERRORS + 1))
fi

# --- 7. DUPLICACY BACKUP (PHOTOS + DUMP) ---
echo "--- STEP 3: DUPLICACY BACKUP ---"
if ! cd "$SOURCE_PATH"; then
    echo "ERROR: Cannot access folder $SOURCE_PATH"
    SCRIPT_ERRORS=$((SCRIPT_ERRORS + 1))
else
    if [ ! -d ".duplicacy" ]; then
        echo "ERROR: Folder $SOURCE_PATH is not initialized with Duplicacy."
        SCRIPT_ERRORS=$((SCRIPT_ERRORS + 1))
    else
        START_BACKUP=$(date +%s)
        if ! stdbuf -oL -eL "$DUPLICACY_BIN" backup -stats -threads "$THREADS"; then
            BACKUP_EXIT=1
        else
            BACKUP_EXIT=0
        fi
        END_BACKUP=$(date +%s)

        # --- 8. CLEANUP AND RETENTION (30 DAYS) ---
        if [ $BACKUP_EXIT -eq 0 ]; then
            echo "Backup completed successfully in $((END_BACKUP - START_BACKUP))s."
            echo "Applying retention: deleting archives > 30 days..."
            if ! "$DUPLICACY_BIN" prune -keep 0:30; then
                echo "WARNING: Cleanup (prune) failed."
                SCRIPT_ERRORS=$((SCRIPT_ERRORS + 1))
            fi
        else
            echo "ERROR: Duplicacy backup failed."
            SCRIPT_ERRORS=$((SCRIPT_ERRORS + 1))
        fi
    fi
fi

# --- 9. RESTART SERVICES ---
echo "--- STEP 4: RESTART SERVICES ---"
if docker compose -f "$COMPOSE_FILE" up -d; then
    echo "Services restarted successfully."
else
    echo "CRITICAL ERROR: Failed to restart services via Docker Compose."
    SCRIPT_ERRORS=$((SCRIPT_ERRORS + 1))
fi

# --- 10. AVAILABILITY CHECK ---
echo "--- STEP 5: SERVICE HEALTH CHECK ---"
MAX_RETRIES=12
RETRY_COUNT=0
SERVICE_UP=false

echo "Waiting for Immich API availability (max $((MAX_RETRIES * 10))s)..."
sleep 10
while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
    if curl -s -f "$IMMICH_HEALTH_URL" | grep -q "pong"; then
        echo "Success: Immich API is responding correctly."
        SERVICE_UP=true
        break
    fi
    RETRY_COUNT=$((RETRY_COUNT + 1))
    echo "Attempt $RETRY_COUNT/$MAX_RETRIES: Service is not ready yet. Waiting 10s..."
    sleep 10
done

if [ "$SERVICE_UP" = false ]; then
    echo "CRITICAL ERROR: Immich API is unreachable after restart."
    SCRIPT_ERRORS=$((SCRIPT_ERRORS + 1))
fi

# --- 11. FINAL REPORT AND UNRAID NOTIFICATION ---
TOTAL_DURATION=$(( $(date +%s) - START_TOTAL ))
D_STR=$(printf '%02dh:%02dm:%02ds' $((TOTAL_DURATION/3600)) $((TOTAL_DURATION%3600/60)) $((TOTAL_DURATION%60)))
CURRENT_DAY_OF_WEEK=$(date +%u) # 1=Monday, ..., 7=Sunday

if [ $SCRIPT_ERRORS -gt 0 ]; then
    /usr/local/emhttp/webGui/scripts/notify -e -s "Immich Backup: FAILED" -d "One or more errors occurred during backup. Details: $LOG_FILE"
elif [ "$CURRENT_DAY_OF_WEEK" -eq 1 ]; then
    /usr/local/emhttp/webGui/scripts/notify -i normal -s "Immich Backup: SUCCESS (Weekly)" -d "Backup completed successfully in $D_STR. 30d retention OK."
else
    echo "Backup successful in $D_STR. Notification skipped (only on Mondays or on error)."
fi

echo "================================================================"
echo "END OF SCRIPT: $(date)"
echo "================================================================"

# --- ADDITION: COPY LOG TO DESTINATION ---
# '|| true' prevents set -e from failing the script at the end if the Freebox is unreachable
mkdir -p "$FREEBOX_LOG_DIR" || true
cp "$LOG_FILE" "$FREEBOX_LOG_DIR/" || true

# Release lock
flock -u 9