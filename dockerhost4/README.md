# dockerhost4 backup scripts

Deploys on dockerhost4 (10.10.10.93). Backs up the Immich Postgres DB, the
Immich stack's own config, and the entire fileserver4 mount (which already
contains Immich's library, since
`UPLOAD_LOCATION=/mnt/fileserver4/immich/uploads`) to a Synology NAS at
10.10.10.91, nightly, over rsync-over-SSH.

The target is a **restore from these backups alone**, assuming dockerhost4
itself is gone. That's why the stack config is captured too: the compose
file, `.env` and the running image tags live in `/opt/immich-taco/immich-app`,
outside `/mnt/fileserver4`, so nothing in a snapshot would otherwise tell you
what `DB_PASSWORD` was or which Immich build the dump came from.

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
3. Confirm the key path in `backup-common.sh` (`SSH_KEY`) matches where you
   generated `id_ed25519_immichbackup`.

## Deploy

One-time, on dockerhost4:

```bash
sudo git clone https://github.com/tacoresearch/immich-backup.git /opt/immich-backup
sudo chmod +x /opt/immich-backup/dockerhost4/{backup-immich.sh,prune-snapshots.sh,update.sh}

sudo crontab -e
# paste in the contents of crontab.snippet (points at /opt/immich-backup/dockerhost4/backup-immich.sh)
```

The repo is public, so no credentials are needed to clone it.

## Updating later

Whenever this repo changes (new script version, retention tweak, whatever),
pick it up on dockerhost4 with:

```bash
sudo /opt/immich-backup/dockerhost4/update.sh
```

That's a `git pull --ff-only` plus re-applying `chmod +x`, no manual
copying, no remembering which files changed. Nothing needs to be re-added
to cron, since cron already points at a path inside the cloned repo.
The only exception is if you wanted to change the scheduled backup time, you would have to consider how and where to edit the cron settings, either by following these instructions again after update, or, just manual editing using ctontab -e .

## First run

Test manually before trusting cron with it:

```bash
sudo /opt/immich-backup/dockerhost4/backup-immich.sh
tail -f /var/log/immich-backup.log
```

Then check on the NAS side that:

- `/volume1/backups/immich/db` has a dated `.sql.gz` file.
- `/volume1/backups/fileserver4-snapshots` has a `YYYY-MM-DD` folder (with
  content under `.../immich/uploads/`) plus a `latest` symlink pointing at it.
- `/volume1/backups/hostconfig/YYYY-MM-DD/` has `docker-compose.yml`, `.env`
  and `versions.txt`. Check `versions.txt` actually lists real image tags and
  digests rather than `?` / `n/a`, since that file is what a future restore
  uses to pull the right Immich build.
- `/volume1/backups/logs` has a matching `backup_YYYY-MM-DD.log` with a
  start/finish/duration/data-transferred/rate summary for that run.

## important note about first run
Only one run can hold the lock at a time; if you kick off a manual run near 2am, that night's cron run will just log 'Another backup run is already in progress' and exit.

## This is what a sucessful backup look like
```bash
root@dockerhost4:~# /opt/immich-backup/dockerhost4/backup-immich.sh 2>&1 | tee -a /var/log/immich-backup.log
[2026-08-03 20:29:36] Checking connection to 10.10.10.91...
[2026-08-03 20:29:36] Dumping Immich Postgres database (immich_postgres)...
[2026-08-03 20:33:16] Syncing fileserver4 mount (/mnt/fileserver4) into snapshot 2026-08-04...
--link-dest arg does not exist: ../latest

Number of files: 510,008 (reg: 432,651, dir: 77,357)
Number of created files: 509,096 (reg: 432,642, dir: 76,454)
Number of deleted files: 0
Number of regular files transferred: 432,642
Total file size: 141,045,744,229 bytes
Total transferred file size: 133,321,440,650 bytes
Literal data: 133,321,440,650 bytes
Matched data: 0 bytes
File list size: 45,209,321
File list generation time: 0.002 seconds
File list transfer time: 0.000 seconds
Total bytes sent: 133,397,737,115
Total bytes received: 8,826,235

sent 133,397,737,115 bytes  received 8,826,235 bytes  10,689,200.22 bytes/sec
total size is 141,045,744,229  speedup is 1.06
[2026-08-04 00:01:17] Nothing to prune (1 snapshots, all within retention windows).
[2026-08-04 00:01:39] Disk usage on NAS:
[2026-08-04 00:01:58]   133G    /volume1/backups/fileserver4-snapshots
[2026-08-04 00:01:58]   918M    /volume1/backups/immich/db
[2026-08-04 00:01:58] Summary: 125GiB in 3h 32m 22s (10.46 MB/s), log saved to /volume1/backups/logs/backup_2026-08-04.log
[2026-08-04 00:01:58] Backup complete.
```



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
- **`hostconfig/` contains secrets.** `.env` holds `DB_PASSWORD` in
  plaintext, so the script writes it mode 600 inside a 700 directory. That's
  a deliberate tradeoff: a restore that can't authenticate to its own
  database isn't a restore. It does sharpen the open question below about the
  `immichbackup` account being in `administrators`. Note that a lost `.env`
  is *recoverable* even so, since `pg_dumpall` restores the old password hash
  and you can simply `ALTER ROLE postgres WITH PASSWORD '<new>'` afterward to
  match a freshly written `.env`.
- Only a whitelist of filenames is copied out of `/opt/immich-taco/immich-app`,
  not the whole directory. Immich's default `DB_DATA_LOCATION` is `./postgres`,
  i.e. the live Postgres data directory sits alongside the compose file, and
  copying that would be gigabytes of redundant, crash-inconsistent data when
  we already have a clean logical dump.
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
