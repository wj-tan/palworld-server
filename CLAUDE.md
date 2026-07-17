# CLAUDE.md — operating rules for this project

Guidance for any AI/Claude Code session working in this repo. Read before provisioning
or modifying OCI resources.

## 🔒 Rule 1 — Always Free tier only (hard constraint)

**Only provision OCI resources that fall within the Always Free tier. Never create a paid
resource without explicit, per-instance user confirmation** that names the expected cost.

Before creating, resizing, or launching ANY OCI resource:
1. **Re-check the live limits** (see Rule 2) — do not trust memory or this file's cached
   numbers; they change.
2. Confirm the requested resource fits within Always Free.
3. If it does not (e.g. x86 `VM.Standard.E5.Flex`, extra block storage, a load balancer,
   a second A1 instance that exceeds the shared allowance), **stop and ask the user first**,
   stating the estimated cost.

### Known Always-Free ceilings for this project (verify against Rule 2 each time)
- **Compute (ARM Ampere A1):** `1,500 OCPU-hours + 9,000 GB-hours / month` ≈ **2 OCPU / 12 GB
  running 24/7**. This is the shared total across ALL A1 instances — a second instance or a
  larger one spills into **paid** usage on Pay-As-You-Go.
- **Block/boot storage:** 200 GB combined total.
- **Object Storage:** 20 GB + 50,000 requests/month.
- **Outbound transfer:** 10 TB/month. **VCN:** 2.
- `VM.Standard.E2.1.Micro` (AMD, 1/8 OCPU, 1 GB) ×2 is also Always Free, but too small for Palworld.

### Not free — require explicit confirmation
- Any x86 shape (`E5.Flex`, `E4.Flex`, etc.) — **paid** (native, no box64, but billed).
- A1 usage beyond 2 OCPU / 12 GB total, storage beyond 200 GB, load balancers, most databases
  beyond the 2 free Autonomous instances, reserved capacity, etc.

### Cost safety expected to stay in place
- Keep the tenancy **budget + alert** active (this project: $5/month → user's email).
- Prefer `scripts/manage.sh stop` over leaving paid/test instances running.
- After any test on paid resources, terminate them (`scripts/teardown.sh`).

## 🔄 Rule 2 — Always index the latest Always Free docs

The authoritative, frequently-updated source of truth for what is Always Free:

> **https://docs.oracle.com/en-us/iaas/Content/FreeTier/freetier_topic-Always_Free_Resources.htm**

**Fetch this URL (WebFetch) at the start of any task that provisions/changes OCI resources**,
and use its current numbers — Oracle changes allocations over time (e.g. the A1 allowance has
changed before). If the live page disagrees with the ceilings cached above in Rule 1 or in
`docs/OCI-NOTES.md`, **the live page wins** — follow it and update those files to match.

