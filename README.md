# Palworld Dedicated Server on Oracle Cloud (OCI)

A reusable, config-driven setup for running a [Palworld](https://store.steampowered.com/app/1623730/Palworld/)
dedicated server on an OCI compute instance — including networking, a self-deploying
instance, off-site backups, and lifecycle management scripts.

Runs on **ARM (Always Free)** via box64 emulation, or **x86 (paid, native)**.

---

## What you get

- **One-command network setup** — VCN, internet gateway, firewall rules, subnet.
- **Self-deploying instance** — cloud-init installs Docker and starts Palworld
  (via [`thijsvanloef/palworld-server-docker`](https://github.com/thijsvanloef/palworld-server-docker)),
  with the OCI-specific firewall/apt-lock fixes already handled.
- **Capacity retry** — the launcher retries through the free-tier "Out of host capacity" error.
- **Off-site backups** — compressed saves pushed to OCI Object Storage on a schedule,
  auto-expiring (well within the 20 GB free tier).
- **Save import** — load an existing world (e.g. a converted single-player save) onto the
  server in one command, with an automatic pre-import backup and a printed rollback command.
- **One-command updates** — pull the latest Palworld build with an automatic pre-update
  backup, and auto-recovery if the ARM/box64 download stalls.
- **Management scripts** — start/stop/status/logs/ssh, reset the world, full teardown.
- **Always-Free guardrail** — a compartment quota that *hard-caps* the tenancy to free-tier
  allowances, so a mistake can't provision paid compute. Important on Pay-As-You-Go, which
  silently raises your service limits (A1 cores 2 → 250).

## Prerequisites

1. An OCI account. For free ARM, upgrading to **Pay-As-You-Go** greatly improves
   capacity availability (an idle 2 OCPU / 12 GB A1 instance stays free — see `docs/OCI-NOTES.md`).
2. **OCI CLI** configured on your machine:
   ```bash
   pip install oci-cli
   # Add an API key in the OCI console (Profile -> API keys) and create ~/.oci/config
   ```
3. An **SSH keypair** for the instance:
   ```bash
   ssh-keygen -t ed25519 -f ~/.ssh/palworld_oci -N ""
   ```
4. Bash (Git Bash on Windows) + Python (for the OCI CLI).

## Quick start

```bash
cp config.env.example config.env      # then edit: region, passwords, server name...
scripts/04-quota-guardrail.sh         # (do this first) hard-cap the tenancy to Always Free
scripts/01-network.sh                 # create the VCN/subnet/firewall
scripts/02-launch.sh                  # launch the instance; it self-deploys Palworld
scripts/03-backup-setup.sh            # (optional) off-site backups to Object Storage

scripts/manage.sh status              # check instance + container health
scripts/manage.sh logs                # watch the server come up (box64 first boot is slow)
```

Connect in-game via **direct connect** to `<PUBLIC_IP>:8211` (shown by `manage.sh status`),
using `SERVER_PASSWORD` from your `config.env` if set.

## Everyday commands

| Command | Does |
|---|---|
| `scripts/manage.sh status` | Instance state, container health, public IP |
| `scripts/manage.sh ip` | Print current public IP (it's ephemeral) |
| `scripts/manage.sh stop` | Graceful stop — halts compute billing, keeps disk |
| `scripts/manage.sh start` | Boot the instance again (IP may change) |
| `scripts/manage.sh logs` | Tail the Palworld container logs |
| `scripts/manage.sh restart` | Restart just the game container |
| `scripts/manage.sh ssh` | Interactive SSH into the instance |
| `scripts/update-server.sh [--no-backup] [--no-wait]` | Update to the latest Palworld build (backs up first) |
| `scripts/import-save.sh <save.zip\|.tar.gz\|dir>` | Load an existing/converted world onto the server (backs up first) |
| `scripts/reset-world.sh [--purge-offsite]` | Wipe saves for a fresh world |
| `scripts/teardown.sh [--all]` | Terminate instance (`--all` also deletes network + bucket) |

## Changing game/server settings

Edit `config.env` and re-run `scripts/02-launch.sh` for a fresh instance, **or** for an
existing server, SSH in and edit `~/palworld/docker-compose.yml`, then
`docker compose up -d`. The container supports many `PalWorldSettings.ini` overrides as
env vars (XP rate, capture rate, day length, etc.) — see the
[image docs](https://palworld-server-docker.loef.dev/).

## Loading an existing world (save import)

To move an existing world onto the server - a converted single-player/co-op save, a backup from
another host, or one of this project's own off-site snapshots:

```bash
scripts/import-save.sh Palworld-converted-save.zip
```

It accepts a `.zip`, a `.tar.gz`, or a directory, and finds the save root by locating `Level.sav`
inside it.
Archives that wrap the files in a folder, or that contain a whole `SaveGames/0/<WorldID>` tree,
work as-is.

The files are installed into the world folder the server is already configured to load
(`DedicatedServerName` in `GameUserSettings.ini`), so the world ID, your server settings and the
backup cron all keep working - nothing needs re-pointing.

Before anything is overwritten the script flushes the live world to disk with an RCON `Save`,
takes a fresh off-site backup, and writes a local rollback tarball to
`~/palworld/import-rollback/` on the server (the last 5 are kept).
It then stops the container, swaps the files in, restarts, waits for the server to report healthy,
and prints the exact rollback command.

| Option | Does |
|---|---|
| `--with-world-option` | Also import `WorldOption.sav` (see the caveat below) |
| `--keep-players` | Keep the player saves already on the server; import only the world |
| `--world <ID>` | Target a specific world folder instead of the configured one |
| `--no-backup` | Skip the pre-import off-site backup (the rollback tarball is still written) |
| `--yes` | Skip the confirmation prompt |

Two files in a typical converted save are skipped by default:

- **`WorldOption.sav`** takes priority over `PalWorldSettings.ini` on a dedicated server, so
  importing it silently discards the game settings from your `config.env` (player cap, passwords,
  rates).
  Pass `--with-world-option` only if you specifically want the world's original settings to win.
  Any `WorldOption.sav` already on the server is removed unless you pass that flag, so the two
  runs stay consistent.
- **`LocalData.sav`** is a single-player-only file that a dedicated server never reads.

A few things to know:

- **Converting a save is a separate step.** This script imports a save that is already in
  dedicated-server form; use a tool such as
  [`palworld-save-tools`](https://github.com/cheahjs/palworld-save-tools) to convert a
  single-player/Xbox save first, so the player UIDs match what a dedicated server expects.
- **The server rewrites the save on its next autosave**, so file sizes will not match the archive
  afterwards - it re-serializes the world and drops single-player-only data.
  The real check is joining the server and seeing your bases and characters.
- **Players online are disconnected** by the container restart; the script warns if anyone is on.
- **First boot after the swap can take a while**, because the restart re-runs SteamCMD
  (`UPDATE_ON_BOOT=true`) and may pull a new Palworld build.
  The script waits up to ~20 minutes for a healthy status; the import itself is already on disk,
  so Ctrl-C is safe.

## Updating to a new Palworld version

When Palworld ships an update, run:

```bash
scripts/update-server.sh
```

It takes a fresh off-site backup, pulls the latest server image, and recreates the container
so SteamCMD downloads the new build on boot (`UPDATE_ON_BOOT=true`).
Your world is stored on a separate volume, so it is preserved across the update.

On ARM the SteamCMD verify step sometimes falls back to a full ~5 GB re-download and can even
freeze mid-download under box64.
The script waits for the server to report healthy and automatically nudges a stalled download
with a container restart, so you can leave it running.
Use `--no-backup` to skip the pre-update backup, or `--no-wait` to start the update and return
immediately (then watch `scripts/manage.sh logs`).

## Layout

```
CLAUDE.md                 operating rules (Always-Free-only + always check live limits)
config.env(.example)      your settings (config.env is gitignored — holds passwords)
cloud-init/               first-boot deploy template (OCI fixes baked in)
scripts/                  provisioning + management (source lib.sh for shared helpers)
state/                    current instance/network OCIDs (gitignored, machine-specific)
docs/OCI-NOTES.md         free-tier limits + the gotchas this project already handles
```

> **Cost policy:** this project is Always-Free-only. `CLAUDE.md` instructs any AI assistant
> to verify resources against the [live Always Free docs](https://docs.oracle.com/en-us/iaas/Content/FreeTier/freetier_topic-Always_Free_Resources.htm)
> before provisioning and to ask before creating anything paid.

See `docs/OCI-NOTES.md` before your first run — it explains the free-tier math and the
non-obvious OCI issues (host firewall, OCPU vs vCPU, box64 caveats) this setup solves.

## License

MIT — see [LICENSE](LICENSE).
