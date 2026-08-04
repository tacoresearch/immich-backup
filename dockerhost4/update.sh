#!/usr/bin/env bash
# Brings this deploy target back in line with GitHub. origin is the single
# source of truth: local modifications here are DISCARDED, not merged.
#
# Why not `git pull --ff-only` (what this used to do): the chmod below sets
# the +x bit, and that bit is part of a file's identity in git. With the
# scripts committed as mode 100644, every run of this script left three files
# showing as modified, and the *next* run then aborted with "Your local
# changes to the following files would be overwritten by merge". update.sh
# reliably broke its own next invocation.
#
# A hard reset is also just the honest behaviour for this box. Nothing here is
# meant to be edited in place; changes belong in the repo and arrive by
# running this. Anything edited directly on dockerhost4 is a mistake we want
# overwritten, not preserved into a merge conflict.
#
# Untracked files are deliberately left alone (no `git clean`), so anything
# dropped into the directory by hand still survives.
#
#   sudo /opt/immich-backup/dockerhost4/update.sh

set -euo pipefail

# The entire body is wrapped in a brace group so bash parses all of it before
# executing any of it. A script that rewrites itself mid-run can otherwise
# leave bash reading from a stale byte offset in the new file and executing
# garbage. This script rewrites itself by design, so the guard matters.
{
  BRANCH="main"

  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  REPO_DIR="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"

  echo "Fetching origin/$BRANCH..."
  git -C "$REPO_DIR" fetch --quiet origin "$BRANCH"

  BEFORE="$(git -C "$REPO_DIR" rev-parse --short HEAD)"

  # Report anything about to be thrown away. A hand-edit on this box should
  # leave a trace in the log rather than vanishing silently.
  if ! git -C "$REPO_DIR" diff --quiet HEAD --; then
    echo
    echo "NOTE: discarding local modifications on this deploy target:"
    git -C "$REPO_DIR" status --short
    echo
  fi

  git -C "$REPO_DIR" reset --hard "origin/$BRANCH"

  # Kept as a safety net even once the +x bit is committed: it is a no-op then,
  # and still covers a filesystem or transfer that drops the mode.
  chmod +x "$SCRIPT_DIR/backup-immich.sh" \
           "$SCRIPT_DIR/prune-snapshots.sh" \
           "$SCRIPT_DIR/update.sh"

  AFTER="$(git -C "$REPO_DIR" rev-parse --short HEAD)"
  if [[ "$BEFORE" == "$AFTER" ]]; then
    echo "Already up to date at $AFTER."
  else
    echo "Updated: $BEFORE -> $AFTER"
    git -C "$REPO_DIR" log --oneline "$BEFORE..$AFTER" | sed 's/^/  /'
  fi

  exit 0
}
