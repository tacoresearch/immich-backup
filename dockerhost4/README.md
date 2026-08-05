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

> **Recovering right now?** Go straight to **[restore.md](restore.md)**. It
> covers the full "the VM is gone" procedure, and also the much smaller job of
> pulling a single deleted photo back out of a snapshot.

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
# Match the host clock to Immich's TZ first -- see "Timezone" below for why
sudo timedatectl set-timezone America/New_York
sudo systemctl restart cron

sudo git clone https://github.com/tacoresearch/immich-backup.git /opt/immich-backup
sudo chmod +x /opt/immich-backup/dockerhost4/{backup-immich.sh,prune-snapshots.sh,update.sh}

sudo crontab -e
# paste in the contents of crontab.snippet (points at /opt/immich-backup/dockerhost4/backup-immich.sh)
```

The repo is public, so no credentials are needed to clone it.

### Timezone

dockerhost4 shipped with its system clock on UTC while Immich's `.env` sets
`TZ=America/New_York`. That split caused two problems worth understanding,
since both were invisible until they were looked for:

- **cron ran at the wrong time.** cron reads the host clock, so `0 2 * * *`
  fired at 02:00 UTC, i.e. **10pm Eastern**, not overnight as intended.
- **Snapshots were named for the wrong day.** `backup-immich.sh` sources
  Immich's `.env` with `set -a`, which exports `TZ` into the script. Anything
  evaluating `date` *before* that source ran in UTC; anything after ran in
  Eastern. A backup starting at 20:29 Eastern was already 00:29 UTC, so it
  named its snapshot for the following day while its own log lines said
  otherwise.

The script side is fixed (`DATE` and `START_HUMAN` are now computed after the
`.env` source, with a comment explaining why the ordering matters). The host
side is the `timedatectl` command above. With both aligned, the system clock,
`journalctl`, the cron schedule, the backup log, and the snapshot folder names
all finally agree.

The schedule is **3am, not 2am**, deliberately: US daylight-saving transitions
happen at exactly 2:00 AM local, so a 2am job sits on the one hour that is
skipped each spring and repeated each fall.

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
- Restoring: see **[restore.md](restore.md)** for the full procedure, run by
  `restore-immich.sh`. The short version is that each dated folder is a
  complete, independent tree (thanks to hardlinking, not a diff you need to
  replay against other nights), so pulling individual files back out is just
  a copy, with no database or containers involved.
- Not included: `/mnt/bobnology` (Synology at 10.10.10.185). It wasn't
  selected for this round since it's already external storage in its own
  right.
- Logs append forever at `/var/log/immich-backup.log`; add a logrotate
  entry if that becomes a problem.
- cron silently skips a run if the machine happened to be off at 3am, so a
  VM down overnight for maintenance just quietly has no backup for that day.
  A systemd timer with `Persistent=true` would catch up on next boot instead,
  and takes a timezone directly (`OnCalendar=*-*-* 03:00:00 America/New_York`).
  Worth considering later; it would replace `crontab.snippet` entirely.
- The `immichbackup` NAS account is in the `administrators` group (created
  that way for rsync/SMB access during setup). Worth a look later at whether
  it can be scoped down to just read/write on the `backups` shared folder.

## Considered, not done

Raised while building this and deliberately left alone. None are bugs; each is
an open question with a real cost attached, recorded so they don't get
rediscovered from scratch later.

- **Keep local copies of the Docker images.** `restore-immich.sh` pins to the
  digests in `versions.txt`, which is exact but still depends on GitHub's
  registry still hosting those builds on the day you need them. Realistically
  that's safe for a year or two and a coin flip at five. `docker save` writes
  the actual image bytes to a file we control (~3-5GB for the whole stack,
  against a 133GB library, so cheap). It would be wasteful nightly since the
  images rarely change, but the script could save them only when a digest
  differs from the previous night's, which in practice is a few times a year.
  Note this only matters for restoring an *old* snapshot as a running system;
  see the point below about what old snapshots are actually for.
- **Nothing alerts on failure.** The `ERR` trap writes to the log and exits
  non-zero, but no one is told. A broken mount, an unreachable NAS, or a
  failed dump would simply mean no backup that night, silently, until someone
  happened to look. A healthchecks.io ping or a mail-on-failure would close
  this. Currently the only detection is noticing the absence of a new dated
  folder.
- **No restore has actually been performed.** Until one has, this is a backup
  system that is only theoretically a restore system. The intended proof is
  standing up a clean VM and running `restore-immich.sh` against it end to
  end.
- **The mount's credentials file, if it has one.** `/etc/fstab` is captured,
  but not any separate credentials file it references (e.g. a CIFS
  `credentials=/root/.smbcreds`). If the fileserver4 mount needs one, a
  rebuild has the mount definition but not the secret satisfying it.
- **Whether Immich uses External Libraries is unconfirmed.** If it does,
  those paths depend on extra volume mounts in the compose file, and a restore
  onto different storage would need them replicated. Everything in the managed
  `UPLOAD_LOCATION` tree is already handled; this is only about libraries
  Immich indexes in place.

Worth knowing when weighing the first point: restoring a *five-year-old*
snapshot as a running system is not really the use case. Old snapshots exist
so you can retrieve a photo deleted years ago, and for that the database and
the Immich version are irrelevant, since the files are plain files sitting in
`fileserver4-snapshots/<date>/`. Full-system restores realistically come from
recent snapshots, where image availability isn't in question.

Already noted above and still open: the `immichbackup` account's
`administrators` membership, logrotate for `/var/log/immich-backup.log`, and
replacing cron with a systemd timer to survive the machine being off at 3am.
