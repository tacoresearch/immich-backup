#!/usr/bin/env bash
# Pulls the latest version of these scripts and re-applies executable
# permissions (git doesn't always preserve the +x bit reliably across
# clone/pull depending on how it was committed). Run any time you want
# to pick up changes made in the repo:
#   /opt/immich-backup/dockerhost4/update.sh
set -euo pipefail

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

git -C .. pull --ff-only
chmod +x backup-immich.sh prune-snapshots.sh update.sh

echo "Updated. Now at commit: $(git -C .. rev-parse --short HEAD)"
