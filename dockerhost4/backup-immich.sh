#!/usr/bin/env bash
# Nightly Immich backup on dockerhost4 (10.10.10.93).
#
# Transport: rsync over SSH, straight to the NAS at 10.10.10.91
# (immichbackup@10.10.10.91, key-only auth, no daemon/module involved).
#
# Snapshot-style, NOT mirror-only: every run writes to its own dated
# folder on the NAS (fileserver4-snapshots/YYYY-MM-DD/), hardlinking
# unchanged files from the previous night via --link-dest so it doesn't
# cost a full extra copy each night. Deletions are only ever "visible"
# within that one night's folder; every earlier night's snapshot is a
# separate directory that a bad run literally cannot touch. That's the
# point: an accidental mass-delete (or a flaky mount making the source
# look empty) can waste one night's snapshot at worst, it can't destroy
# history the way a single reused mirror + `rsync --delete` could.
#
#   1. Immich Postgres dump (pg_dumpall, per Immich's own documented
#      backup method), dated + gzipped ->
#      /volume1/backups/immich/db/immich_db_YYYY-MM-DD.sql.gz
#   2. The entire /mnt/fileserver4 mount, dated ->
#      /volume1/backups/fileserver4-snapshots/YYYY-MM-DD/
#      (Immich's UPLOAD_LOCATION is /mnt/fileserver4/immich/uploads, i.e.
#      already inside this mount, so it rides along here rather than
#      getting a separate, duplicate sync.)
#   3. A summary log for this run ->
#      /volume1/backups/logs/backup_YYYY-MM-DD.log
#
# Retention isn't a flat cutoff: prune-snapshots.sh (run automatically
# at the end of this script) thins old snapshots to weekly, then
# monthly, then yearly, rather than deleting anything outright once
# it crosses one age threshold. It prunes the matching DB dump and
# summary log for any date it removes, too. See that script for the
# exact windows.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/backup-common.sh"

LOCKFILE="/var/run/immich-backup.lock"
exec 200>"$LOCKFILE"
flock -n 200 || { echo "[$(date '+%F %T')] Another backup run is already in progress, exiting."; exit 1; }

log() { echo "[$(date '+%F %T')] $*"; }
trap 'log "Backup FAILED at line $LINENO"' ERR

START_EPOCH=$(date +%s)
START_HUMAN=$(date '+%F %T')

# --- Config ---
IMMICH_DIR="/opt/immich-taco/immich-app"
ENV_FILE="$IMMICH_DIR/.env"

# Confirmed via `docker ps --format '{{.Names}}'` on dockerhost4
DB_CONTAINER="immich_postgres"

FILESERVER_MOUNT="/mnt/fileserver4"

DATE="$(date +%F)"
SNAP_DIR="$REMOTE_SNAPSHOT_BASE/$DATE"

# --- Pull DB_USERNAME / UPLOAD_LOCATION out of Immich's own .env ---
if [[ ! -f "$ENV_FILE" ]]; then
  log "ERROR: $ENV_FILE not found. Is IMMICH_DIR correct?"
  exit 1
fi
set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

: "${DB_USERNAME:?DB_USERNAME missing from $ENV_FILE}"
: "${UPLOAD_LOCATION:?UPLOAD_LOCATION missing from $ENV_FILE}"

if [[ "$UPLOAD_LOCATION" != /* ]]; then
  UPLOAD_LOCATION="$IMMICH_DIR/$UPLOAD_LOCATION"
fi

# --- Guardrails (avoid wasting a snapshot slot on a bad mount, not "protect the only copy" anymore) ---
if ! mountpoint -q "$FILESERVER_MOUNT"; then
  log "ERROR: fileserver4 network mount ($FILESERVER_MOUNT) is not mounted. Aborting."
  exit 1
fi

if [[ ! -d "$UPLOAD_LOCATION" ]] || [[ -z "$(ls -A "$UPLOAD_LOCATION" 2>/dev/null)" ]]; then
  log "ERROR: Immich upload location ($UPLOAD_LOCATION) is missing or empty. Aborting."
  exit 1
fi

log "Checking connection to $REMOTE_HOST..."
if ! ssh "${SSH_OPTS[@]}" "$REMOTE_USER@$REMOTE_HOST" true; then
  log "ERROR: could not reach $REMOTE_USER@$REMOTE_HOST over SSH. Aborting."
  exit 1
fi

ssh "${SSH_OPTS[@]}" "$REMOTE_USER@$REMOTE_HOST" \
  "mkdir -p '$REMOTE_DB_DIR' '$REMOTE_SNAPSHOT_BASE' '$REMOTE_LOG_DIR'"

# --- 1. Database dump, dated, streamed straight to the NAS (atomic: .tmp then remote mv) ---
log "Dumping Immich Postgres database ($DB_CONTAINER)..."
docker exec -t "$DB_CONTAINER" pg_dumpall --clean --if-exists --username="$DB_USERNAME" \
  | gzip \
  | ssh "${SSH_OPTS[@]}" "$REMOTE_USER@$REMOTE_HOST" \
      "cat > '$REMOTE_DB_DIR/immich_db_$DATE.sql.gz.tmp' && mv '$REMOTE_DB_DIR/immich_db_$DATE.sql.gz.tmp' '$REMOTE_DB_DIR/immich_db_$DATE.sql.gz'"
DB_SIZE=$(ssh "${SSH_OPTS[@]}" "$REMOTE_USER@$REMOTE_HOST" "du -h '$REMOTE_DB_DIR/immich_db_$DATE.sql.gz'" | cut -f1)

# --- 2. Entire fileserver4 mount, as a dated snapshot (covers Immich's library, see header note) ---
# --stats gives the transfer totals used in the summary log below; `tee /dev/stderr`
# keeps the live warning/summary lines visible (e.g. the expected first-run
# "--link-dest arg does not exist" notice) even though the output is also
# being captured into a variable.
log "Syncing fileserver4 mount ($FILESERVER_MOUNT) into snapshot $DATE..."
RSYNC_STATS="$(rsync -a --delete --link-dest="../latest" --stats -e "$RSYNC_RSH" \
  "$FILESERVER_MOUNT"/ "$REMOTE_USER@$REMOTE_HOST:$SNAP_DIR"/ | tee /dev/stderr)"

# --- Point "latest" at tonight's snapshot (atomic rename, used as next run's --link-dest base) ---
ssh "${SSH_OPTS[@]}" "$REMOTE_USER@$REMOTE_HOST" \
  "ln -s '$DATE' '$REMOTE_SNAPSHOT_BASE/.latest.tmp' && mv -Tf '$REMOTE_SNAPSHOT_BASE/.latest.tmp' '$REMOTE_SNAPSHOT_BASE/latest'"

# --- Thin old snapshots (daily -> weekly -> monthly -> yearly, never all-gone) ---
"$SCRIPT_DIR/prune-snapshots.sh"

SNAPSHOT_SIZE=$(ssh "${SSH_OPTS[@]}" "$REMOTE_USER@$REMOTE_HOST" "du -sh '$SNAP_DIR'" | cut -f1)

log "Disk usage on NAS:"
ssh "${SSH_OPTS[@]}" "$REMOTE_USER@$REMOTE_HOST" \
  "du -sh '$REMOTE_SNAPSHOT_BASE' '$REMOTE_DB_DIR'" | while IFS= read -r line; do log "  $line"; done

# --- Summary log, written to the NAS alongside the backup it describes ---
END_EPOCH=$(date +%s)
END_HUMAN=$(date '+%F %T')
DURATION_SECONDS=$((END_EPOCH - START_EPOCH))
DURATION_HUMAN=$(printf '%dh %dm %ds' $((DURATION_SECONDS/3600)) $(((DURATION_SECONDS%3600)/60)) $((DURATION_SECONDS%60)))

# "Total transferred file size" is the actual new/changed bytes this run
# (unchanged files were hardlinked, not transferred), which is what makes
# the rate figure meaningful run over run.
TRANSFERRED_BYTES=$(printf '%s\n' "$RSYNC_STATS" | grep -oP 'Total transferred file size: \K[0-9,]+' | tr -d ',' || echo 0)
TRANSFERRED_HUMAN=$(numfmt --to=iec-i --suffix=B "$TRANSFERRED_BYTES" 2>/dev/null || echo "${TRANSFERRED_BYTES} bytes")
if [[ "$DURATION_SECONDS" -gt 0 && "$TRANSFERRED_BYTES" -gt 0 ]]; then
  RATE_HUMAN=$(awk -v b="$TRANSFERRED_BYTES" -v s="$DURATION_SECONDS" 'BEGIN { printf "%.2f MB/s", (b/1000000)/s }')
else
  RATE_HUMAN="n/a"
fi

{
  echo "Immich backup summary -- $DATE"
  echo "================================"
  echo "Started:              $START_HUMAN"
  echo "Finished:              $END_HUMAN"
  echo "Duration:              $DURATION_HUMAN"
  echo "Data transferred:      $TRANSFERRED_HUMAN (new/changed only, unchanged files were hardlinked)"
  echo "Average rate:          $RATE_HUMAN"
  echo "DB dump size:          $DB_SIZE"
  echo "Snapshot total size:   $SNAPSHOT_SIZE (full tree, via hardlinks)"
  echo
  echo "rsync --stats output:"
  echo "$RSYNC_STATS"
} | ssh "${SSH_OPTS[@]}" "$REMOTE_USER@$REMOTE_HOST" \
    "cat > '$REMOTE_LOG_DIR/backup_$DATE.log.tmp' && mv '$REMOTE_LOG_DIR/backup_$DATE.log.tmp' '$REMOTE_LOG_DIR/backup_$DATE.log'"

log "Summary: $TRANSFERRED_HUMAN in $DURATION_HUMAN ($RATE_HUMAN), log saved to $REMOTE_LOG_DIR/backup_$DATE.log"
log "Backup complete."
