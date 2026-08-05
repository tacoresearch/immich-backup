# Restoring Immich from the NAS backups

This is the "dockerhost4 is gone" procedure. Not "Immich is misbehaving",
not "I deleted a photo", but *the VM no longer exists*. See
[Retrieving individual files](#retrieving-individual-files-without-a-restore)
below if you only need a file or two back, because that is a much smaller job
and doesn't need any of this.

Everything needed comes out of the backup itself: the compose file, the `.env`
with its `DB_PASSWORD`, and the exact image digests that were running. Nothing
has to be remembered or reconstructed.

**The new host does not have to resemble the old one.** Immich's compose maps
`UPLOAD_LOCATION` (a host path) to a fixed path *inside* the container, and the
database only ever stores the container-side path. `/mnt/fileserver4` appears
nowhere in the database. So a flat local disk works exactly as well as the old
network mount: point `--path` anywhere and the script rewrites
`UPLOAD_LOCATION` in the restored `.env` to match.

## Before you start

1. **A working Docker host.** See
   [tacoresearch/dockerhost](https://github.com/tacoresearch/dockerhost).
   Docker and either `docker compose` or `docker-compose` must be installed.
2. **The Immich stack repo**, if you want a directory for the stack to land
   in. See [tacoresearch/immich-taco](https://github.com/tacoresearch/immich-taco).
   Strictly optional for a normal restore, since the compose file and `.env`
   both come out of the backup, but you need it if you are restoring a
   snapshot old enough to predate the `hostconfig/` capture.
3. **SSH access from the new host to the NAS** (`immichbackup@10.10.10.91`).
   If the old key died with the old VM, either put it back at
   `/root/.ssh/id_ed25519_immichbackup` or just let the script prompt for the
   password. Unlike `backup-immich.sh`, this script deliberately does not set
   `BatchMode`, precisely so a password prompt works.
4. **Enough disk.** The full library is roughly 133GB. The script checks and
   refuses to start if the target filesystem can't hold it.
5. **This repo**, cloned to the new host:
   ```bash
   sudo git clone https://github.com/tacoresearch/immich-backup.git /opt/immich-backup
   sudo chmod +x /opt/immich-backup/dockerhost4/*.sh
   ```

## Running it

Check the plan first. This changes nothing:

```bash
sudo /opt/immich-backup/dockerhost4/restore-immich.sh \
  --host "$(hostname)" --path /srv/immich-data --dry-run
```

Then run it for real:

```bash
sudo /opt/immich-backup/dockerhost4/restore-immich.sh \
  --host "$(hostname)" --path /srv/immich-data
```

Expect roughly **4 hours** for a full 133GB restore, dominated by per-file
overhead across ~430,000 files rather than raw bandwidth. Run it under `tmux`
or `screen` so an SSH drop doesn't kill it.

### Options

| Flag | Meaning |
|---|---|
| `--host <name>` | **Required.** Must match this machine's `hostname` exactly. |
| `--path <dir>` | **Required.** Where the library goes. Becomes `UPLOAD_LOCATION`. |
| `--stack-dir <dir>` | Where compose and `.env` land. Default `/opt/immich-taco/immich-app`. |
| `--snapshot <date>` | Restore a specific `YYYY-MM-DD` instead of the newest. |
| `--no-pin` | Pull current image tags instead of the backed-up digests. See below. |
| `--yes` | Skip the confirmation prompt. |
| `--dry-run` | Show the plan, change nothing. |

`--host` is not bureaucracy. It is the interlock that stops this being fired
at a working production server by muscle memory.

## What it does

Preflight runs entirely before anything is fetched, so an abort costs seconds
rather than hours. It checks for root, that `--host` matches, that `--path`
isn't inside `/mnt/fileserver4`, that required commands exist, and that **no
Immich containers already exist on this host**.

Then it resolves `latest` **once** to a concrete date. Everything afterward
reads from that fixed folder, so a backup running on the source host mid-restore
cannot shift the ground underneath it.

After you confirm:

1. **Stack config** is restored to `--stack-dir`, and `UPLOAD_LOCATION` is
   rewritten from the old `/mnt/fileserver4/...` path to your `--path`.
2. **Images are pinned** to the digests in `versions.txt`, so you get the exact
   builds that produced this dump rather than whatever `:v2` points at today.
3. **The library** is pulled, including `thumbs/` and `encoded-video/`. Both
   are technically regenerable, but regenerating them for a library this size
   is hours of CPU already paid for at backup time.
4. **Ownership is reported, not changed.** rsync ran as the unprivileged
   `immichbackup` user on the NAS and could not preserve original UIDs.
   Immich's containers run as root by default, in which case what lands is
   fine. If you run Immich as a non-root UID, `chown` the tree before starting.
5. **The database** is restored into a Postgres that has never been started by
   Immich, using Immich's documented `search_path` workaround and
   `--single-transaction`.
6. **The role password is re-aligned** with `.env`, then the full stack starts.

### Why the database step is fussy

Immich requires a Postgres that its server has *never* started, because
Immich's own migrations would otherwise collide with the dump. That's why the
script runs `docker compose create` and starts only the database service,
rather than bringing the stack up.

The `sed` in the restore pipeline is mandatory, not cosmetic. It is part of
Immich's own documented procedure and works around `search_path` handling in
the vector extension in their custom Postgres image. Without it the restore
fails outright.

## Verifying

```bash
cd /opt/immich-taco/immich-app
docker compose ps                      # all services healthy
docker compose logs -f immich-server
```

Then, in the web UI:

1. **Log in with your original credentials.** They came from the restored
   database, not from anything in `.env`. If your old password works, the
   database restore genuinely succeeded.
2. **Open photos from several different years.** Thumbnails rendering proves
   the library copied. Full images opening proves the paths resolve.

## When things go wrong

**`refusing to run: --host says X but this machine is Y`**
The interlock. If this really is the target, pass `--host Y`.

**`existing Immich containers found on this host`**
The script will not tear down a stack for you, by design. A script that
quietly destroys databases is not one you want running at 3am. Remove them
yourself:
```bash
cd /opt/immich-taco/immich-app && docker compose down -v
```
`down -v` **destroys the Postgres volume**. That is what you want here and
exactly what you never want anywhere else.

**`image pull failed while pinned to the backed-up digests`**
Those builds have most likely been garbage-collected upstream. Re-run with
`--no-pin`, accepting that you'll get a newer Immich than the dump came from
and that it will migrate the database forward on first start.

**`no captured stack config for <date>`**
That snapshot predates the `hostconfig/` capture. The script falls back to
whatever is already in `--stack-dir`, so deploy
[immich-taco](https://github.com/tacoresearch/immich-taco) first and re-run.
A fresh `.env` will have a new `DB_PASSWORD`, which is handled: `pg_dumpall`
restores the *old* password hash, and the script's `ALTER ROLE` step then
re-aligns it with whatever the new `.env` says.

**Photos missing but thumbnails render**
The library copy is incomplete rather than the paths being wrong. Re-run with
the same `--snapshot`; rsync fills in only what's absent.

**Postgres never becomes ready**
The script polls for 10 minutes. On very slow storage, check
`docker compose logs database` for the real cause before raising that.

## Testing a restore

The above assumes the host is empty. To *test* against a machine that already
has Immich on it, you must tear the stack down yourself first, including the
volume (`docker compose down -v`), or power the VM off and start from a clean
one. The script refuses to proceed otherwise and will not do it for you.

## What this does not restore

- **`/etc/fstab`.** It is captured to `hostconfig/<date>/fstab` for reference,
  so you can see how fileserver4 was mounted, but nothing replays it. The
  machine being restored onto may have entirely different storage, and
  writing someone else's mount table is a good way to make a host fail to boot.
- **Any credentials file `fstab` points at**, such as a CIFS
  `credentials=/root/.smbcreds`. Recreate by hand if the mount needs one.
- **The host OS, Docker, or networking.** See
  [tacoresearch/dockerhost](https://github.com/tacoresearch/dockerhost).

## Retrieving individual files without a restore

If you only want a photo back, none of the above applies. Snapshots are plain
directory trees, so just copy the file out:

```bash
ssh immichbackup@10.10.10.91 \
  "ls /volume1/backups/fileserver4-snapshots/"          # pick a date

scp immichbackup@10.10.10.91:'/volume1/backups/fileserver4-snapshots/2026-08-04/immich/uploads/library/...' .
```

No database, no containers, no version matching. This is also what old
snapshots are really for: a five-year-old snapshot is a file archive, not a
realistic full-system restore candidate.
