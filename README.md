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
- **Management scripts** — start/stop/status/logs/ssh, reset the world, full teardown.

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
| `scripts/reset-world.sh [--purge-offsite]` | Wipe saves for a fresh world |
| `scripts/teardown.sh [--all]` | Terminate instance (`--all` also deletes network + bucket) |

## Changing game/server settings

Edit `config.env` and re-run `scripts/02-launch.sh` for a fresh instance, **or** for an
existing server, SSH in and edit `~/palworld/docker-compose.yml`, then
`docker compose up -d`. The container supports many `PalWorldSettings.ini` overrides as
env vars (XP rate, capture rate, day length, etc.) — see the
[image docs](https://palworld-server-docker.loef.dev/).

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
