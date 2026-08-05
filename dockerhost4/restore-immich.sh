#!/usr/bin/env bash
# Disaster recovery for Immich, from the NAS backups alone.
#
# The assumption this is built around: dockerhost4 is GONE. Not broken, gone.
# There is no /mnt/fileserver4, no /opt/immich-taco, no SSH key, nothing but a
# fresh VM and whatever is sitting on the NAS at 10.10.10.91. Everything this
# script needs therefore comes out of the backup, including the compose file,
# the .env, and the exact image digests that were running.
#
# It restores, in order:
#   1. The Immich stack config     <- /volume1/backups/hostconfig/<date>/
#   2. The photo/video library     <- /volume1/backups/fileserver4-snapshots/<date>/
#   3. The Postgres database       <- /volume1/backups/immich/db/immich_db_<date>.sql.gz
#
# The new host does NOT need to look like the old one. Immich's compose maps
# UPLOAD_LOCATION (a host path) to a fixed path inside the container, and the
# database only ever stores the container-side path. So a flat local disk works
# exactly as well as the old network mount: point --path anywhere and this
# script rewrites UPLOAD_LOCATION in the restored .env to match.
#
# PREREQUISITES, in this order:
#   1. A rebuilt Docker host        -> https://github.com/tacoresearch/dockerhost
#   2. The Immich stack repo        -> https://github.com/tacoresearch/immich-taco
#   3. SSH access from this box to the NAS. If the old key died with the old
#      VM, either copy it back to /root/.ssh/id_ed25519_immichbackup or just
#      let this script prompt for the immichbackup password. Unlike the backup
#      script, this one does NOT set BatchMode, precisely so that works.
#
# USAGE
#   sudo ./restore-immich.sh --host <this-hostname> --path <upload-location>
#
# --host must match this machine's actual hostname. That is not bureaucracy:
# it is the interlock that stops this being run on a working production host.
#
# WHAT THIS SCRIPT DELIBERATELY WILL NOT DO
#   It never runs `docker compose down -v`. That command destroys the Postgres
#   volume, and a script that quietly wipes databases is not one you want to
#   run at 3am under pressure. If a stack is already up here, this aborts and
#   tells you to tear it down yourself.
#
#   That matters most when TESTING a restore against an existing instance:
#   power the VM off, or remove the containers and volumes by hand, before
#   running this. The restore needs a Postgres that has never been started by
#   Immich, because Immich's own migrations would otherwise conflict with the
#   dump.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/backup-common.sh"   # REMOTE_* paths, REMOTE_USER/HOST, SSH_KEY

log()  { echo "[$(date '+%F %T')] $*"; }
warn() { echo "[$(date '+%F %T')] WARNING: $*" >&2; }
die()  { echo "[$(date '+%F %T')] ERROR: $*" >&2; exit 1; }

# --- Defaults / args -------------------------------------------------------

TARGET_HOST=""
RESTORE_PATH=""
STACK_DIR="/opt/immich-taco/immich-app"
SNAPSHOT=""
ASSUME_YES=0
DRY_RUN=0
PIN_IMAGES=1

usage() {
  cat <<'USAGE'
Usage: restore-immich.sh --host <hostname> --path <upload-location> [options]

Required:
  --host <name>     Hostname of THIS machine. Must match `hostname` exactly.
                    Safety interlock against running on the wrong box.
  --path <dir>      Where the Immich library should live on this host. Becomes
                    UPLOAD_LOCATION in the restored .env. Any path works; it
                    does not need to resemble the old /mnt/fileserver4 layout.

Options:
  --stack-dir <dir> Where to write the restored compose file and .env.
                    Default: /opt/immich-taco/immich-app
  --snapshot <date> Restore a specific YYYY-MM-DD instead of the newest.
  --no-pin          Pull whatever the compose file's image tags resolve to
                    today, instead of the exact digests recorded at backup
                    time. Use this if a pinned pull fails because the registry
                    no longer has those builds.
  --yes             Skip the confirmation prompt.
  --dry-run         Show what would happen, change nothing.
  -h, --help        This text.

Example:
  sudo ./restore-immich.sh --host immich-new --path /srv/immich-data
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host)      TARGET_HOST="${2:-}"; shift 2 ;;
    --path)      RESTORE_PATH="${2:-}"; shift 2 ;;
    --stack-dir) STACK_DIR="${2:-}"; shift 2 ;;
    --snapshot)  SNAPSHOT="${2:-}"; shift 2 ;;
    --no-pin)    PIN_IMAGES=0; shift ;;
    --yes)       ASSUME_YES=1; shift ;;
    --dry-run)   DRY_RUN=1; shift ;;
    -h|--help)   usage; exit 0 ;;
    *)           usage; die "unknown argument: $1" ;;
  esac
done

[[ -n "$TARGET_HOST"  ]] || { usage; die "--host is required"; }
[[ -n "$RESTORE_PATH" ]] || { usage; die "--path is required"; }

# --- Guards ----------------------------------------------------------------
# All of these run before anything is fetched or written. A restore that
# aborts in preflight costs nothing; one that aborts halfway costs hours.

[[ $EUID -eq 0 ]] || die "must run as root (docker, /opt, and chown all need it)"

ACTUAL_HOST="$(hostname)"
if [[ "$ACTUAL_HOST" != "$TARGET_HOST" ]]; then
  die "refusing to run: --host says '$TARGET_HOST' but this machine is '$ACTUAL_HOST'.
       This interlock exists so a restore cannot be fired at the wrong server.
       If '$ACTUAL_HOST' really is the intended target, pass --host $ACTUAL_HOST."
fi

# The old production mount. If the restore target is inside it, we would be
# writing the restored library on top of the live library.
if [[ "$RESTORE_PATH" == /mnt/fileserver4* ]]; then
  die "refusing to restore into $RESTORE_PATH: that is the production mount.
       Pick a path on this host's own storage."
fi

for cmd in docker rsync ssh gunzip gzip sed awk grep df; do
  command -v "$cmd" >/dev/null 2>&1 || die "required command not found: $cmd"
done

if docker compose version >/dev/null 2>&1; then
  DC=(docker compose)
elif command -v docker-compose >/dev/null 2>&1; then
  DC=(docker-compose)
else
  die "neither 'docker compose' nor 'docker-compose' is available"
fi

# A running (or even previously-started) Immich means Postgres already has
# schema and migration state of its own, which the dump will collide with.
RUNNING="$(docker ps -a --filter "name=immich" --format '{{.Names}}' || true)"
if [[ -n "$RUNNING" ]]; then
  die "existing Immich containers found on this host:
$(printf '  %s\n' $RUNNING)
       This script will not tear them down for you, by design.
       Remove them and their volumes first, or power this VM off and start
       from a clean one:
         cd $STACK_DIR && ${DC[*]} down -v
       Note that 'down -v' DESTROYS the Postgres volume. That is what you want
       here and exactly what you do not want anywhere else."
fi

# --- SSH to the NAS --------------------------------------------------------
# Deliberately NOT BatchMode: after a total loss the key is gone with the old
# VM, and falling back to a password prompt beats failing outright.

SSH_OPTS_R=(-o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new)
RSYNC_RSH_R="ssh -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new"
if [[ -f "$SSH_KEY" ]]; then
  SSH_OPTS_R+=(-i "$SSH_KEY")
  RSYNC_RSH_R="ssh -i $SSH_KEY -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new"
  log "Using SSH key $SSH_KEY"
else
  warn "SSH key $SSH_KEY not found; you will be prompted for the $REMOTE_USER password (possibly several times)."
fi

nas() { ssh "${SSH_OPTS_R[@]}" "$REMOTE_USER@$REMOTE_HOST" "$@"; }

log "Checking connection to $REMOTE_HOST..."
nas true || die "cannot reach $REMOTE_USER@$REMOTE_HOST over SSH"

# --- Pick the snapshot -----------------------------------------------------
# Resolved ONCE, to a concrete date. Everything downstream reads from that
# fixed folder, so a backup running on the source host mid-restore (which
# only ever creates a new dated folder and moves the symlink) cannot shift
# the ground under us.

if [[ -z "$SNAPSHOT" ]]; then
  SNAPSHOT="$(nas "readlink '$REMOTE_SNAPSHOT_BASE/latest' 2>/dev/null || true")"
  if [[ -z "$SNAPSHOT" ]]; then
    warn "no 'latest' symlink on the NAS, falling back to the newest dated folder"
    SNAPSHOT="$(nas "find '$REMOTE_SNAPSHOT_BASE' -maxdepth 1 -mindepth 1 -type d -name '????-??-??' -printf '%f\n' | sort -r | head -1")"
  fi
fi
[[ -n "$SNAPSHOT" ]] || die "could not determine which snapshot to restore"
[[ "$SNAPSHOT" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || die "snapshot '$SNAPSHOT' is not a YYYY-MM-DD date"

SNAP_DIR="$REMOTE_SNAPSHOT_BASE/$SNAPSHOT"
DUMP_REMOTE="$REMOTE_DB_DIR/immich_db_$SNAPSHOT.sql.gz"
HOSTCONFIG_REMOTE="$REMOTE_HOSTCONFIG_DIR/$SNAPSHOT"

nas "test -d '$SNAP_DIR'"    || die "snapshot directory missing on NAS: $SNAP_DIR"
nas "test -f '$DUMP_REMOTE'" || die "database dump missing on NAS: $DUMP_REMOTE"

HAVE_HOSTCONFIG=1
if ! nas "test -f '$HOSTCONFIG_REMOTE/.env'"; then
  HAVE_HOSTCONFIG=0
  warn "no captured stack config for $SNAPSHOT ($HOSTCONFIG_REMOTE/.env)."
  warn "That capture was added later, so older snapshots predate it."
  warn "Falling back to the compose file and .env already in $STACK_DIR."
  [[ -f "$STACK_DIR/.env" ]] || die "no fallback either: $STACK_DIR/.env does not exist.
       Deploy the stack from https://github.com/tacoresearch/immich-taco first,
       then re-run. Note that a fresh .env will have a NEW DB_PASSWORD, which
       this script handles: see the ALTER ROLE step near the end."
fi

# --- Sizing ----------------------------------------------------------------

log "Measuring $SNAP_DIR (this takes a minute on a large snapshot)..."
NEED_KB="$(nas "du -sk '$SNAP_DIR'" | awk '{print $1}')"
mkdir -p "$RESTORE_PATH"
AVAIL_KB="$(df -Pk "$RESTORE_PATH" | awk 'NR==2 {print $4}')"
human() { awk -v k="$1" 'BEGIN { printf "%.1f GiB", k/1048576 }'; }

log "Snapshot is $(human "$NEED_KB"); $RESTORE_PATH has $(human "$AVAIL_KB") free."
if (( AVAIL_KB < NEED_KB )); then
  die "not enough free space at $RESTORE_PATH (need $(human "$NEED_KB"), have $(human "$AVAIL_KB"))"
fi

# --- Confirm ---------------------------------------------------------------

cat <<SUMMARY

  Restore plan
  ------------
  This host         : $ACTUAL_HOST
  Snapshot          : $SNAPSHOT
  Library source    : $REMOTE_USER@$REMOTE_HOST:$SNAP_DIR
  Library target    : $RESTORE_PATH   ($(human "$NEED_KB") to transfer)
  Database dump     : $DUMP_REMOTE
  Stack config      : $([[ $HAVE_HOSTCONFIG -eq 1 ]] && echo "$HOSTCONFIG_REMOTE" || echo "(none in backup; using existing $STACK_DIR)")
  Stack directory   : $STACK_DIR
  Image versions    : $([[ $PIN_IMAGES -eq 1 ]] && echo "pinned to the digests captured at backup time" || echo "--no-pin: whatever the compose tags resolve to today")

SUMMARY

if [[ $DRY_RUN -eq 1 ]]; then
  log "--dry-run: stopping here, nothing has been changed."
  exit 0
fi

if [[ $ASSUME_YES -eq 0 ]]; then
  read -r -p "Proceed? [yes/NO] " reply
  [[ "$reply" == "yes" ]] || die "aborted by user"
fi

# --- 1. Stack config -------------------------------------------------------

mkdir -p "$STACK_DIR"

if [[ $HAVE_HOSTCONFIG -eq 1 ]]; then
  log "Restoring stack config to $STACK_DIR..."
  rsync -a -e "$RSYNC_RSH_R" \
    "$REMOTE_USER@$REMOTE_HOST:$HOSTCONFIG_REMOTE/" "$STACK_DIR/"
  chmod 600 "$STACK_DIR/.env"
  if [[ -f "$STACK_DIR/versions.txt" ]]; then
    log "Image versions recorded at backup time:"
    sed 's/^/    /' "$STACK_DIR/versions.txt"
  fi
fi

# Read the OLD upload location before overwriting it: the snapshot mirrors the
# whole /mnt/fileserver4 mount, so we need to know which subdirectory of it
# actually held the library.
OLD_UPLOAD="$(awk -F= '/^UPLOAD_LOCATION=/ { sub(/^UPLOAD_LOCATION=/, ""); print; exit }' "$STACK_DIR/.env")"
[[ -n "$OLD_UPLOAD" ]] || die "UPLOAD_LOCATION not found in $STACK_DIR/.env"

FILESERVER_MOUNT="/mnt/fileserver4"
UPLOAD_SUBPATH="${OLD_UPLOAD#"$FILESERVER_MOUNT"/}"
if [[ "$UPLOAD_SUBPATH" == "$OLD_UPLOAD" ]]; then
  die "UPLOAD_LOCATION ($OLD_UPLOAD) is not under $FILESERVER_MOUNT, so its
       location inside the snapshot cannot be derived. Restore by hand."
fi
log "Library lives at '$UPLOAD_SUBPATH' inside the snapshot."

# Point the restored config at this host's storage instead of the old mount.
# This is the whole reason a different storage topology is a non-issue: the
# container path stays the same, so every path in the database still resolves.
log "Rewriting UPLOAD_LOCATION: $OLD_UPLOAD -> $RESTORE_PATH"
sed -i "s|^UPLOAD_LOCATION=.*|UPLOAD_LOCATION=$RESTORE_PATH|" "$STACK_DIR/.env"

DB_USERNAME="$(awk -F= '/^DB_USERNAME=/ { sub(/^DB_USERNAME=/, ""); print; exit }' "$STACK_DIR/.env")"
DB_DATABASE_NAME="$(awk -F= '/^DB_DATABASE_NAME=/ { sub(/^DB_DATABASE_NAME=/, ""); print; exit }' "$STACK_DIR/.env")"
DB_PASSWORD="$(awk -F= '/^DB_PASSWORD=/ { sub(/^DB_PASSWORD=/, ""); print; exit }' "$STACK_DIR/.env")"
: "${DB_USERNAME:=postgres}"
: "${DB_DATABASE_NAME:=immich}"
[[ -n "$DB_PASSWORD" ]] || die "DB_PASSWORD not found in $STACK_DIR/.env"

# --- 2. Library ------------------------------------------------------------
# Everything, including thumbs/ and encoded-video/. Both are technically
# regenerable, but regenerating them for a library this size is hours of CPU
# we already paid for at backup time.

log "Restoring library from snapshot $SNAPSHOT (this is the long part)..."
rsync -a --info=progress2 --stats -e "$RSYNC_RSH_R" \
  "$REMOTE_USER@$REMOTE_HOST:$SNAP_DIR/$UPLOAD_SUBPATH/" "$RESTORE_PATH/"

# Ownership is reported, not silently "fixed". rsync ran as the unprivileged
# immichbackup user on the NAS and so could not preserve the original UIDs;
# whatever landed here is a consequence of that, and blindly chown-ing 500k
# files to a guess is worse than telling you what you actually have.
log "Ownership of restored files (top level):"
ls -ln "$RESTORE_PATH" | head -n 10 | sed 's/^/    /'
log "Immich's containers run as root by default, in which case the above is fine."
log "If you run Immich as a non-root UID, chown $RESTORE_PATH to it before starting."

# --- 3. Database -----------------------------------------------------------

DUMP_LOCAL="/var/tmp/immich_db_$SNAPSHOT.sql.gz"
log "Fetching database dump to $DUMP_LOCAL..."
rsync -a --info=progress2 -e "$RSYNC_RSH_R" \
  "$REMOTE_USER@$REMOTE_HOST:$DUMP_REMOTE" "$DUMP_LOCAL"

log "Verifying dump integrity..."
gzip -t "$DUMP_LOCAL" || die "$DUMP_LOCAL is corrupt; try an older --snapshot"

dc() { ( cd "$STACK_DIR" && "${DC[@]}" "$@" ); }

# --- Pin images to the builds that produced this dump ----------------------
# The compose file references moving tags (:v2), which Immich re-points at
# every release. Pulling those on restore day hands us a NEWER Immich than the
# dump came from, so the restore and a version upgrade happen simultaneously
# and any failure is ambiguous between the two. The digests in versions.txt
# name the exact builds that were running when this backup was taken.
#
# Caveat worth understanding: a digest is only as durable as the registry
# hosting it. If those builds have since been garbage-collected upstream the
# pull will fail, which is what --no-pin exists for.

PINNED=0
COMPOSE_FILE="$STACK_DIR/docker-compose.yml"

if [[ $PIN_IMAGES -eq 0 ]]; then
  log "--no-pin: using the image tags in the compose file as-is."
elif [[ ! -f "$STACK_DIR/versions.txt" ]]; then
  warn "no versions.txt in this snapshot, so images cannot be pinned."
  warn "Falling back to the compose file's tags, which may resolve to a newer Immich."
else
  log "Pinning compose images to the digests recorded at backup time..."
  while read -r ref; do
    # Skip the 'n/a' placeholders the backup writes when a digest was
    # unavailable for an image.
    [[ "$ref" == *"@sha256:"* ]] || continue
    repo="${ref%%@*}"
    sha="${ref##*@}"
    # Docker's RepoDigests omits the implicit "docker.io/" prefix, so a Docker
    # Hub image records as "valkey/valkey@sha256:..." while compose files
    # normally spell it "docker.io/valkey/valkey:9". Try both spellings, and
    # keep whichever form the compose file actually uses.
    for cand in "$repo" "docker.io/$repo"; do
      if grep -qE "^[[:space:]]*image:[[:space:]]*${cand}[:@]" "$COMPOSE_FILE"; then
        # Replaces the whole tag or digest after the repo name, including a
        # ${IMMICH_VERSION:-release} style variable.
        sed -i -E "s|^([[:space:]]*image:[[:space:]]*)${cand}[:@][^[:space:]]*|\1${cand}@${sha}|" "$COMPOSE_FILE"
        log "  $cand -> $sha"
        PINNED=$((PINNED + 1))
        break
      fi
    done
  done < <(awk '/^[[:space:]]*digest:/ { print $2 }' "$STACK_DIR/versions.txt")

  if [[ $PINNED -eq 0 ]]; then
    warn "no image lines in $COMPOSE_FILE matched versions.txt; using its tags as-is."
  else
    log "Pinned $PINNED image(s)."
  fi
fi

log "Pulling images and creating containers (NOT starting the stack)..."
if ! dc pull; then
  if [[ $PINNED -gt 0 ]]; then
    die "image pull failed while pinned to the backed-up digests.
       Those exact builds have most likely been removed from the registry.
       Re-run with --no-pin to use current tags instead, accepting that you
       will get a newer Immich than this dump came from:
         $0 --host $TARGET_HOST --path $RESTORE_PATH --snapshot $SNAPSHOT --no-pin"
  fi
  die "image pull failed"
fi
dc create

DB_SERVICE="$(dc config --services | grep -E '^(database|postgres|db)$' | head -1 || true)"
[[ -n "$DB_SERVICE" ]] || die "could not identify the Postgres service in $STACK_DIR/docker-compose.yml"

log "Starting only the '$DB_SERVICE' service..."
dc up -d "$DB_SERVICE"

DB_CONTAINER="$(dc ps -q "$DB_SERVICE")"
[[ -n "$DB_CONTAINER" ]] || die "the $DB_SERVICE container did not come up"

# Poll rather than sleep a fixed number of seconds: on a cold VM with slow
# disk, Postgres can take considerably longer than any guess we would make.
log "Waiting for Postgres to accept connections..."
for i in $(seq 1 60); do
  if docker exec "$DB_CONTAINER" pg_isready -U "$DB_USERNAME" -q 2>/dev/null; then
    log "  ready after ${i}0s" ; break
  fi
  [[ $i -eq 60 ]] && die "Postgres did not become ready within 10 minutes"
  sleep 10
done

# The sed is mandatory, not cosmetic. It is part of Immich's own documented
# restore procedure and works around the search_path handling of the vector
# extension in their custom Postgres image. Without it the restore fails.
log "Restoring database into '$DB_DATABASE_NAME' as '$DB_USERNAME'..."
gunzip --stdout "$DUMP_LOCAL" \
  | sed "s/SELECT pg_catalog.set_config('search_path', '', false);/SELECT pg_catalog.set_config('search_path', 'public, pg_catalog', true);/g" \
  | docker exec -i "$DB_CONTAINER" psql \
      --dbname="$DB_DATABASE_NAME" \
      --username="$DB_USERNAME" \
      --single-transaction \
      --set ON_ERROR_STOP=on

# pg_dumpall carries role definitions INCLUDING password hashes, so the
# restore just reset this role's password to whatever the old host used. If
# the .env came out of the same backup those already agree and this is a
# harmless no-op. If the .env is a fresh one, they do not, and Immich would
# fail to connect with an error that looks nothing like the actual cause.
log "Re-aligning the '$DB_USERNAME' role password with $STACK_DIR/.env..."
# Doubling any single quote is how SQL escapes one inside a literal. Without
# this a password containing an apostrophe would end the string early and the
# rest of it would be parsed as SQL.
DB_PASSWORD_SQL="${DB_PASSWORD//\'/\'\'}"
docker exec -i "$DB_CONTAINER" psql --username="$DB_USERNAME" --dbname="$DB_DATABASE_NAME" \
  -v ON_ERROR_STOP=on -c "ALTER ROLE \"$DB_USERNAME\" WITH PASSWORD '$DB_PASSWORD_SQL';" >/dev/null

# --- 4. Bring the stack up -------------------------------------------------

log "Starting the full stack..."
dc up -d

rm -f "$DUMP_LOCAL"

cat <<DONE

  Restore complete, from snapshot $SNAPSHOT.

  Verify, in this order:
    1. ${DC[*]} -f $STACK_DIR/docker-compose.yml ps      # all services healthy
    2. ${DC[*]} -f $STACK_DIR/docker-compose.yml logs -f immich-server
    3. Log in to the web UI with your ORIGINAL credentials. They came from the
       restored database, not from anything in .env.
    4. Open a photo from several different years. Thumbnails proving out means
       the library copied; full images opening means the paths resolve.

  If images are missing but thumbnails render, the library copy is incomplete
  rather than the paths being wrong; re-run with the same --snapshot, rsync
  will fill in only what is absent.

DONE

log "Done."
