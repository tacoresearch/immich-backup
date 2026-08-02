# dockerhost4 backup scripts

Deploys on dockerhost4 (10.10.10.93). Backs up the Immich Postgres DB and the
entire fileserver4 mount (which already contains Immich's library, since
`UPLOAD_LOCATION=/mnt/fileserver4/immich/uploads`) to a Synology NAS at
10.10.10.91, nightly, over rsync-over-SSH.

This is **snapshot-style, not mirror-only**: every run writes a new dated
folder (`fileserver4-snapshots/YYYY-MM-DD/`), hardlinking anything unchanged
from the previous night so it doesn't cost a full extra copy each time. A bad
delete, a bug, or a flaky mount can only ever waste *one night's* snapshot,
it can't touch or erase any earlier night's folder. That was a deliberate
call: with `rsync --delete` against a single reused destination, an
accidental mass-deletion on dockerhost4 would have propagated straight
through to the (only) backup on the very next run. Photos are irreplaceable
and deletions here are expected to be rare/intentional, so keeping history
around costs a bit more disk but removes that failure mode entirely.

## Already done (this round of testing)

- Confirmed the NAS's rsync daemon (port 873) exists but isn't the path we're
  using, its module auth is a separate credential store from the DSM user
  account and turned out to be more friction than it's worth.
- Enabled SSH on the NAS, enabled the "User Home" service so accounts get a
  real home directory, and confirmed `immichbackup@10.10.10.91` can log in.
- Generated a dedicated, passphrase-less keypair on dockerhost4
  (`/root/.ssh/id_ed25519_immichbackup`) and authorized it on the NAS, so the
  nightly cron job can rsync without a password prompt.

## Before deploying

1. ~~Confirm the Immich Postgres container name~~ Done: `immich_postgres`,
   confirmed via `docker ps --format '{{.Names}}'`.
2. ~~Confirm `.env` location and its `DB_USERNAME`/`UPLOAD_LOCATION`~~ Done:
   the compose stack actually lives at `/opt/immich-taco/immich-app` (one
   level deeper than the repo root), `DB_USERNAME=postgres`,
   `UPLOAD_LOCATION=/mnt/fileserver4/immich/uploads`. `IMMICH_DIR` in the
   script is already set to match.
3. Confirm the key path in `backup-immich.sh` (`SSH_KEY`) matches where you
   generated `id_ed25519_immichbackup`.

## Deploy

```bash
sudo mkdir -p /opt/immich-taco/backup
sudo cp backup-immich.sh prune-snapshots.sh backup-common.sh /opt/immich-taco/backup/
sudo chmod +x /opt/immich-taco/backup/backup-immich.sh /opt/immich-taco/backup/prune-snapshots.sh

sudo crontab -e
# paste in the contents of crontab.snippet
```

`backup-common.sh` doesn't need `chmod +x`, it's sourced, not executed
directly. All three files need to stay in the same directory since
`backup-immich.sh` calls the other two by relative path.

## First run

Test manually before trusting cron with it:

```bash
sudo /opt/immich-taco/backup/backup-immich.sh
tail -f /var/log/immich-backup.log
```

Then check on the NAS side that `/volume1/backups/immich/db` has a dated
`.sql.gz` file, `/volume1/backups/fileserver4-snapshots` has a `YYYY-MM-DD`
folder (with content under `.../immich/uploads/`) plus a `latest` symlink
pointing at it, and `/volume1/backups/logs` has a matching
`backup_YYYY-MM-DD.log` with a start/finish/duration/data-transferred/rate
summary for that run.

## Notes

- The summary log needs `numfmt` and `grep -P` on dockerhost4 to format
  byte counts and pull rsync's transfer total out of `--stats` output.
  Both are standard on Debian; if either's missing the script falls back to
  raw byte counts / an empty match rather than failing the whole backup.

- **Retention is grandfather-father-son, not a flat cutoff** (see
  `prune-snapshots.sh`): every snapshot for the last 14 days, then one per
  ISO week for the next 8 weeks, then one per calendar month for the next 12
  months, then one per calendar year forever after that. Nothing is ever
  fully deleted, it just gets coarser-grained with age. Runs automatically
  at the end of every `backup-immich.sh` call. The script logs `du -sh`
  totals every run so you can watch actual usage trend over time; the
  `KEEP_DAILY`/`KEEP_WEEKLY`/`KEEP_MONTHLY` constants at the top of
  `prune-snapshots.sh` are adjustable if you want a different balance later.
- Restoring a specific day: just copy files out of
  `fileserver4-snapshots/<date>/` and use the matching `immich_db_<date>.sql.gz`.
  Each dated folder is a complete, independent tree (thanks to hardlinking,
  not a diff you need to replay against other nights).
- Not included: `/mnt/bobnology` (Synology at 10.10.10.185). It wasn't
  selected for this round since it's already external storage in its own
  right.
- Logs append forever at `/var/log/immich-backup.log`; add a logrotate
  entry if that becomes a problem.
- The `immichbackup` NAS account is in the `administrators` group (created
  that way for rsync/SMB access during setup). Worth a look later at whether
  it can be scoped down to just read/write on the `backups` shared folder.
