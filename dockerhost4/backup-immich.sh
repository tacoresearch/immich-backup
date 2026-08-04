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
#   2. The Immich stack's own config (compose file, .env, resolved image
#      tags), dated ->
#      /volume1/backups/hostconfig/YYYY-MM-DD/
#      None of this lives under /mnt/fileserver4, so without it a
#      "the whole VM is gone" restore would have the photos and the
#      database but nothing to run them in.
#   3. The entire /mnt/fileserver4 mount, dated ->
#      /volume1/backups/fileserver4-snapshots/YYYY-MM-DD/
#      (Immich's UPLOAD_LOCATION is /mnt/fileserver4/immich/uploads, i.e.
#      already inside this mount, so it rides along here rather than
#      getting a separate, duplicate sync.)
#   4. A summary log for this run ->
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

# Epoch, so it's timezone-independent; the human-readable form is derived
# from it further down, after .env has set TZ (see the note there).
START_EPOCH=$(date +%s)

# --- Config ---
IMMICH_DIR="/opt/immich-taco/immich-app"
ENV_FILE="$IMMICH_DIR/.env"

# Confirmed via `docker ps --format '{{.Names}}'` on dockerhost4
DB_CONTAINER="immich_postgres"

FILESERVER_MOUNT="/mnt/fileserver4"

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

# --- Everything below here is timestamped in Immich's timezone, not the host's ---
# Immich's .env sets TZ, and `set -a` above exported it, so `date` now agrees
# with the timestamps in this script's own log lines. DATE in particular MUST
# be computed here rather than before the source: dockerhost4's system clock is
# UTC, so a run starting at 20:29 Eastern was already 00:29 UTC and named its
# snapshot for the *following* day, disagreeing with its own log output.
#
# START_HUMAN is derived from START_EPOCH rather than a fresh `date` call so it
# still reflects the true start of the run, just rendered in the right zone.
#
# Caveat: the few log lines that can fire before this point (the flock
# collision message, the missing-.env error) are necessarily still stamped in
# the host's timezone, since TZ isn't known yet.
START_HUMAN=$(date -d "@$START_EPOCH" '+%F %T')
DATE="$(date +%F)"
SNAP_DIR="$REMOTE_SNAPSHOT_BASE/$DATE"

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
  "mkdir -p '$REMOTE_DB_DIR' '$REMOTE_SNAPSHOT_BASE' '$REMOTE_LOG_DIR' '$REMOTE_HOSTCONFIG_DIR'"

# --- 1. Database dump, dated, streamed straight to the NAS (atomic: .tmp then remote mv) ---
log "Dumping Immich Postgres database ($DB_CONTAINER)..."
docker exec -t "$DB_CONTAINER" pg_dumpall --clean --if-exists --username="$DB_USERNAME" \
  | gzip \
  | ssh "${SSH_OPTS[@]}" "$REMOTE_USER@$REMOTE_HOST" \
      "cat > '$REMOTE_DB_DIR/immich_db_$DATE.sql.gz.tmp' && mv '$REMOTE_DB_DIR/immich_db_$DATE.sql.gz.tmp' '$REMOTE_DB_DIR/immich_db_$DATE.sql.gz'"
DB_SIZE=$(ssh "${SSH_OPTS[@]}" "$REMOTE_USER@$REMOTE_HOST" "du -h '$REMOTE_DB_DIR/immich_db_$DATE.sql.gz'" | cut -f1)

# --- 2. The Immich stack's own config ---
# DB_PASSWORD, UPLOAD_LOCATION and the exact image tags all live in
# $IMMICH_DIR, which is outside /mnt/fileserver4 and therefore in no
# snapshot. Without them a rebuild-from-scratch restore stalls on
# "what password did the database have?".
#
# Deliberately a whitelist of filenames rather than the whole directory:
# Immich's default DB_DATA_LOCATION is ./postgres, i.e. the live Postgres
# data directory sits in here too, and we already have a logical dump of
# that. Copying it would be gigabytes of redundant, crash-inconsistent data.
#
# This runs before the multi-hour rsync on purpose, so a failure here costs
# seconds rather than surfacing at the end of the night.
#
# NOTE: .env holds DB_PASSWORD in plaintext, so the remote copy is mode 600
# inside a 700 directory. See the README note about this.
log "Capturing Immich stack config from $IMMICH_DIR..."
HOSTCONFIG_DIR="$REMOTE_HOSTCONFIG_DIR/$DATE"
ssh "${SSH_OPTS[@]}" "$REMOTE_USER@$REMOTE_HOST" \
  "mkdir -p '$HOSTCONFIG_DIR' && chmod 700 '$HOSTCONFIG_DIR'"

CONFIG_FILES=()
for f in docker-compose.yml docker-compose.override.yml .env \
         hwaccel.transcoding.yml hwaccel.ml.yml; do
  # if/then rather than `[[ ... ]] &&`, which would make the loop exit
  # non-zero (and trip set -e) whenever the last filename is absent.
  if [[ -f "$IMMICH_DIR/$f" ]]; then CONFIG_FILES+=("$f"); fi
done

for f in "${CONFIG_FILES[@]}"; do
  ssh "${SSH_OPTS[@]}" "$REMOTE_USER@$REMOTE_HOST" \
    "cat > '$HOSTCONFIG_DIR/$f.tmp' && mv '$HOSTCONFIG_DIR/$f.tmp' '$HOSTCONFIG_DIR/$f' && chmod 600 '$HOSTCONFIG_DIR/$f'" \
    < "$IMMICH_DIR/$f"
done

# Resolved image tags AND digests. `:release` is a moving tag, so knowing
# only the tag doesn't tell a future restore which build was actually
# running; the digest pins it exactly.
#
# Note the default is computed here rather than inline below: an apostrophe
# inside a "${VAR:-default}" expansion opens a single-quote context and
# silently eats the rest of the script.
IMMICH_VERSION_NOTE="${IMMICH_VERSION:-unset, so the compose file default applies}"
{
  echo "# Immich stack image versions, captured $(date '+%F %T') on $(hostname)"
  echo "#"
  echo "# Pin these when rebuilding. ':release' moves, so restoring months"
  echo "# from now with a bare ':release' may land on a build newer than the"
  echo "# database dump expects. Restoring into a NEWER Immich generally"
  echo "# migrates forward; restoring into an OLDER one does not work."
  echo "#"
  echo "# IMMICH_VERSION in .env: $IMMICH_VERSION_NOTE"
  echo
  docker ps --filter "name=immich" --format '{{.Names}}' | sort | while IFS= read -r c; do
    img="$(docker inspect --format '{{.Config.Image}}' "$c" 2>/dev/null || echo '?')"
    dig="$(docker image inspect --format '{{if .RepoDigests}}{{index .RepoDigests 0}}{{else}}n/a{{end}}' "$img" 2>/dev/null || echo 'n/a')"
    printf '%s\n  image:  %s\n  digest: %s\n' "$c" "$img" "$dig"
  done
} | ssh "${SSH_OPTS[@]}" "$REMOTE_USER@$REMOTE_HOST" \
      "cat > '$HOSTCONFIG_DIR/versions.txt.tmp' && mv '$HOSTCONFIG_DIR/versions.txt.tmp' '$HOSTCONFIG_DIR/versions.txt'"

log "  saved to $HOSTCONFIG_DIR: ${CONFIG_FILES[*]} versions.txt"

# --- 3. Entire fileserver4 mount, as a dated snapshot (covers Immich's library, see header note) ---
# --stats gives the transfer totals used in the summary log below; `tee /dev/stderr`
# keeps the live warning/summary lines visible (e.g. the expected first-run
# "--link-dest arg does not exist" notice) even though the output is also
# being captured into a variable.
log "Syncing fileserver4 mount ($FILESERVER_MOUNT) into snapshot $DATE..."
# lost+found is a filesystem-reserved directory (every ext4/ZFS volume has
# one), typically root-only at the actual filesystem level and irrelevant
# over a network mount regardless -- excluded rather than worked around,
# since it holds no real data and its permissions aren't ours to fix here.
RSYNC_STATS="$(rsync -a --delete --link-dest="../latest" --stats \
  --exclude="/lost+found" -e "$RSYNC_RSH" \
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
