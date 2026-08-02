#!/usr/bin/env bash
# Shared config, sourced by both backup-immich.sh and prune-snapshots.sh.
# Not meant to be run directly.

REMOTE_USER="immichbackup"
REMOTE_HOST="10.10.10.91"
SSH_KEY="/root/.ssh/id_ed25519_immichbackup"
SSH_OPTS=(-i "$SSH_KEY" -o BatchMode=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new)
RSYNC_RSH="ssh -i $SSH_KEY -o BatchMode=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new"

REMOTE_BASE="/volume1/backups"
REMOTE_DB_DIR="$REMOTE_BASE/immich/db"
REMOTE_SNAPSHOT_BASE="$REMOTE_BASE/fileserver4-snapshots"
REMOTE_LOG_DIR="$REMOTE_BASE/logs"
