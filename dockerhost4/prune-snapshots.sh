#!/usr/bin/env bash
# Thins out old fileserver4 snapshots, DB dumps, stack config captures, and
# summary logs on the NAS.
# Grandfather-father-son style rotation, never fully deletes history:
#
#   age <= KEEP_DAILY days              -> keep every snapshot
#   age <= KEEP_DAILY + KEEP_WEEKLY wks  -> keep the newest snapshot per ISO week
#   age <= that + KEEP_MONTHLY months   -> keep the newest snapshot per calendar month
#   older than all of the above         -> keep the newest snapshot per calendar year, forever
#
# Safe by construction: each dated snapshot folder is a complete,
# independent tree (files are hardlinked across nights via --link-dest,
# not diffed). Deleting any one folder only drops that folder's
# directory entries; files still referenced by other snapshots (or by
# "latest") are untouched, since hardlinks keep the underlying data
# alive until every reference to it is gone.
#
# Called automatically from backup-immich.sh after each nightly run.
# Safe to also run by hand any time to see what it would do -- it just
# recomputes the same keep/delete decision from the dated folder names.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/backup-common.sh"

log() { echo "[$(date '+%F %T')] $*"; }

KEEP_DAILY=14      # days: keep every snapshot this recent
KEEP_WEEKLY=8      # weeks: keep one per ISO week after the daily window
KEEP_MONTHLY=12    # months: keep one per calendar month after the weekly window
# beyond all of the above: keep one per calendar year, forever

mapfile -t SNAPSHOTS < <(
  ssh "${SSH_OPTS[@]}" "$REMOTE_USER@$REMOTE_HOST" \
    "find '$REMOTE_SNAPSHOT_BASE' -maxdepth 1 -mindepth 1 -type d -name '????-??-??' -printf '%f\n'" \
  | sort -r
)

if [[ ${#SNAPSHOTS[@]} -eq 0 ]]; then
  log "No dated snapshots found under $REMOTE_SNAPSHOT_BASE, nothing to prune."
  exit 0
fi

today_epoch=$(date -d "$(date +%F)" +%s)
weekly_cutoff_days=$(( KEEP_DAILY + KEEP_WEEKLY * 7 ))
monthly_cutoff_days=$(( weekly_cutoff_days + KEEP_MONTHLY * 31 ))

declare -A seen_week
declare -A seen_month
declare -A seen_year
to_delete=()

for d in "${SNAPSHOTS[@]}"; do
  d_epoch=$(date -d "$d" +%s 2>/dev/null) || continue
  age_days=$(( (today_epoch - d_epoch) / 86400 ))

  if (( age_days <= KEEP_DAILY )); then
    continue # inside daily window, always keep
  elif (( age_days <= weekly_cutoff_days )); then
    key="w$(date -d "$d" +%G-%V)"
  elif (( age_days <= monthly_cutoff_days )); then
    key="m$(date -d "$d" +%Y-%m)"
  else
    key="y$(date -d "$d" +%Y)"
  fi

  # SNAPSHOTS is newest-first, so the first snapshot seen for a given
  # bucket is the newest one in it -- keep that, delete the rest.
  case "$key" in
    w*) if [[ -n "${seen_week[$key]:-}" ]]; then to_delete+=("$d"); else seen_week[$key]=1; fi ;;
    m*) if [[ -n "${seen_month[$key]:-}" ]]; then to_delete+=("$d"); else seen_month[$key]=1; fi ;;
    y*) if [[ -n "${seen_year[$key]:-}" ]]; then to_delete+=("$d"); else seen_year[$key]=1; fi ;;
  esac
done

if [[ ${#to_delete[@]} -eq 0 ]]; then
  log "Nothing to prune (${#SNAPSHOTS[@]} snapshots, all within retention windows)."
  exit 0
fi

log "Pruning ${#to_delete[@]} of ${#SNAPSHOTS[@]} snapshots (daily<=${KEEP_DAILY}d, weekly<=${KEEP_WEEKLY}w, monthly<=${KEEP_MONTHLY}mo, yearly beyond that)..."
for d in "${to_delete[@]}"; do
  log "  removing snapshot $d (and its DB dump + stack config + summary log, if present)"
  ssh "${SSH_OPTS[@]}" "$REMOTE_USER@$REMOTE_HOST" \
    "rm -rf -- '$REMOTE_SNAPSHOT_BASE/$d' '$REMOTE_HOSTCONFIG_DIR/$d'; rm -f -- '$REMOTE_DB_DIR/immich_db_$d.sql.gz' '$REMOTE_LOG_DIR/backup_$d.log'"
done

log "Prune complete."
