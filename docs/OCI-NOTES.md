# OCI Notes: free-tier limits & gotchas (learned the hard way)

This project already handles the issues below. Kept here so you understand *why*
the scripts do what they do, and what to watch for.

## Always Free limits that matter for Palworld

| Resource | Always Free limit | Our usage |
|---|---|---|
| **Ampere A1 (ARM) compute** | **1,500 OCPU-hours + 9,000 GB-hours / month** = **2 OCPU / 12 GB run 24/7** | 2 OCPU / 12 GB (exactly fits) |
| Block/boot storage | 200 GB total combined | 50 GB boot volume |
| Object Storage | 20 GB + 50k requests/month | ~tens of KB per backup |
| Outbound data transfer | 10 TB / month | trivial |
| VCN | 2 | 1 |

**Key point:** the free ARM allowance is **2 OCPU / 12 GB continuously — not 4/24.**
Running more than one A1 instance, or a bigger one 24/7, spills into **paid** usage on a
Pay-As-You-Go account. One 2/12 instance is the sweet spot.

**x86 (VM.Standard.E5.Flex) is always paid** (~USD 0.0255/OCPU-hr + 0.0015/GB-hr). Handy
for testing (native, no emulation) but not free. Remember **1 OCPU = 2 vCPUs** on x86, so
"4 vCPU" = 2 OCPU when sizing.

## Gotchas this project solves

1. **Palworld is x86-only.** On ARM it runs under **box64** emulation. Set
   `ARM64_DEVICE=generic` (the cloud-init template does). If box64 crashes after a big
   Palworld patch, try `adlink`, or wait for the container image to update.

2. **Host firewall (iptables).** OCI Ubuntu images ship a restrictive `INPUT` chain with a
   catch-all `REJECT`. You must insert ACCEPT rules **above** that REJECT — appending puts
   them below it (dead rules). The cloud-init finds the REJECT line number dynamically.

3. **Two firewall layers.** Opening ports in the OCI **Security List** (done by
   `01-network.sh`) is not enough; the **instance's own iptables** must also allow them
   (done by cloud-init). Both are required.

4. **Boot-time apt lock.** cloud-init's own package step holds the apt/dpkg lock at first
   boot; installing Docker immediately fails. The template waits for the lock to release.

5. **"Out of host capacity" for free ARM.** Common on trial accounts. Upgrading to
   Pay-As-You-Go largely fixes it. `02-launch.sh` retries automatically regardless.

6. **429 "Too many requests".** Hammering the API (e.g. a tight retry loop) throttles you
   for a bit. The launcher backs off on 429s too.

7. **Ephemeral public IP.** Stopping/starting an instance can change its public IP. Use
   `scripts/manage.sh ip` to re-fetch. For a permanent address, attach a **reserved public
   IP** (still free) — not automated here.

8. **box64 first-boot is slow.** The initial ~5 GB SteamCMD download under emulation can
   trip the container healthcheck to `unhealthy` transiently. That's normal — wait for the
   download+verify to finish and it flips to `healthy`.

## Cost safety

Two layers — a budget *detects* overspend after the fact; a quota *prevents* it up front.

### 1. Budget + alert (detective)
- Console: Billing → Budgets → create a budget on the root compartment with a 100% alert.
- This project's account has a **$5/month** budget alert wired to email.

### 2. Compartment quota (preventive) — `scripts/04-quota-guardrail.sh`
**Upgrading to Pay-As-You-Go silently RAISES your service limits** — the free-tier caps stop
applying. Observed on this tenancy after upgrading:

| Limit | Free trial | After PAYG upgrade |
|---|---|---|
| `standard-a1-core-count` | 2 | **250** |
| `standard-a1-memory-count` | 12 | **1666** |
| `standard-e5-core-count` (paid x86) | 0 | **83** |

Nothing then stops an expensive deployment. The quota policy `always-free-guardrail` puts the
ceiling back by policy: A1 capped at 2 OCPU / 12 GB, block storage 200 GB, and all paid compute
shapes zeroed (`VM.Standard.E2.1.Micro` is left alone — it's Always Free).

**Gotchas when working with quotas:**
- Quota **families differ by resource**: cores → `compute-core`, memory → `compute-memory`,
  storage → `block-storage`. Using `compute-core` for a memory quota is rejected.
- Quotas **can** target the root compartment via `in tenancy` — no child compartment needed.
- **`oci limits value list` does NOT reflect quotas.** It shows the raw service limit and will
  still read `250`. The number that gates provisioning is `effective-quota-value` from:
  ```bash
  oci limits resource-availability get --service-name compute \
    --limit-name standard-a1-core-count -c <tenancy> --availability-domain <AD>
  ```
- Quotas apply to **new** provisioning only; existing resources keep running.
- Bonus: with A1 capped at exactly 2 cores and 2 in use, `available` is 0 — which would have
  prevented the duplicate/orphan instance this project once created via a stray retry loop.

## Backups

- **On-server:** the container makes hourly tar backups (7-day retention) + Palworld's own
  rolling world backups.
- **Off-site:** `03-backup-setup.sh` pushes compressed saves to Object Storage every 6h,
  auto-expiring after `BACKUP_RETENTION_DAYS`. Uses a **write-only PAR** (no credentials on
  the box). The PAR **expires after 1 year** — re-run the script to rotate it.
- **Restore:** download the latest `palworld-save_*.tar.gz` from the bucket and extract into
  `~/palworld/data/Pal/Saved/` on the instance (stop the container first).
