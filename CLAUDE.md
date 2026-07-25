# CLAUDE.md — drosera

**Read [README.md](README.md) first** for architecture, setup, credentials, Alloy vs Cloud split, and kiosk (public dashboard). This file keeps **conventions and query patterns** that stay true after the Grafana Cloud migration; it does not duplicate the full setup guide.

## Persona — introduce yourself

When Claude initializes in this directory, open the first response with a
brief self-introduction as **Drosera Claude** — steward of the Lentago Labs
observability suite (Alloy + Grafana Cloud configs in this repo; the LXC 105
host that runs these configs is Home Claude's turf — see `~/CLAUDE.md`). One
sentence is plenty; don't make a meal of it.

## Project overview

**Drosera** is the Lentago Labs observability suite — renamed from
`homelab-observability` on 2026-07-04; AWS telemetry ingestion is the next
scope expansion. **Names that deliberately keep the old
`homelab-observability` prefix:** the OIDC CI role, the Terraform state key
(renaming it would orphan state), the `/opt/homelab-observability` checkouts
on LXC 105 and the bullpen runners, and the derived `homelab-observability_alloy-data`
docker volume (the Alloy WAL).

Firewalla home-network observability: **Grafana Cloud** (dashboards + Mimir + Loki) plus **Grafana Alloy** on a Proxmox LXC for ingestion. Firewalla's Fluent Bit shipper (owned by [lentago/betula](https://github.com/lentago/betula)) ships Zeek (DNS, conn, SSL) and ACL alarm logs **directly** to Grafana Cloud Loki — no LAN relay, no Alloy in the path. The central Alloy's Loki receiver is used only by the `device_inventory` feed (LAN name↔IP resolution; see README § "Device inventory feed"). Metrics: native Alloy blackbox probes (ICMP / HTTP), `node_exporter` on Proxmox hosts, and Home Assistant’s `/api/prometheus` — all remote-written to Grafana Cloud Mimir.

Dashboard JSON lives in [`dashboards/`](dashboards/) and is applied by [`terraform/`](terraform/).

## Stack (current)

| Layer | What |
|-------|------|
| **Grafana Cloud** | UI, `grafanacloud-logs` / `grafanacloud-prom` datasources, dashboards (Terraform-managed) |
| **Alloy** (single `docker compose` service) | `loki.source.api` on `:3100` (device-inventory publisher only — Zeek/ACL logs push directly to Cloud, bypassing this), `prometheus.exporter.blackbox`, scrapes for node + HA, `remote_write` + `loki.write` to Cloud |
| **Bare metal** | `node_exporter` on Proxmox hosts (not in Docker) — see `scripts/deploy-node-exporter.sh` |

Legacy self-hosted Loki + Prometheus + Grafana in one compose file is **removed**; do not reintroduce without an issue.

## File structure (high level)

```
docker-compose.yml          # Alloy only
alloy/config.alloy          # scrape + receive + forward
alloy/blackbox.yml          # icmp, http_2xx modules
alloy/ha_token              # HA bearer token (gitignored); see alloy/ha_token.example
dashboards/*.json           # dashboard source of truth (Terraform reads these)
terraform/*.tf              # Grafana Cloud resources (folder, dashboards, …)
scripts/deploy-node-exporter.sh
scripts/inventory-cloud.sh  # optional snapshot of Cloud API (needs GRAFANA_* env)
claude-cost-export/         # local-session cost exporter + session_running heartbeat
                            # (feeds the Claytonia — Runner Fleet dashboard; rehomed
                            # from workstation-bootstrap when that repo was archived)
```

## Key conventions

- **One flat folder, grouping lives in the title** (2026-07-24 flattening, superseding the 2026-07-18 per-product folder reorg): every drosera-owned dashboard sits in the single **`Lentago`** folder (uid `afh7m8li40zk0d`, the wizard-imported one — retitled, never recreated, because destroying a folder takes its dashboards with it). Titles carry the grouping as `<Group> — <What>`, so the flat alphabetical list still clusters: `Claytonia — …`, `Solidago — …`, `Lentago Lab — …` (homelab-source dashboards; the lab is drosera's first client, not a product), `Sites — <domain>`. A new dashboard **must** take a group prefix — without it the flat list has no structure at all.
- **Dashboard UIDs are frozen legacy names** — `firewalla-<name>` for the lab set and `claude-runner-fleet` for the Claytonia fleet dashboard. UIDs are load-bearing (cross-dashboard `/d/` links, the office-display public share, terraform import blocks); changing one is a destroy/create. New per-site dashboards use `site-<domain-with-dashes>` matching the site repo names (e.g. `site-pondviewlane-com`); new product dashboards use `<product>-<name>` (e.g. `solidago-platform-health`).
- **Loki labels**: `log_source` is the main stream selector — current values are `zeek_dns`, `zeek_conn`, `zeek_ssl`, `firewalla_acl`, plus `device_inventory`. Queries may also see `cluster="lentago-lab"` — Firewalla's Fluent Bit sets it directly (static `Labels` directive) for the four Zeek/ACL streams; Alloy's `external_labels` sets it for `device_inventory`, which still routes through Alloy. Use both `log_source` and `cluster` if a panel is empty. Data ingested before the 2026-07-04 label migration still carries `cluster="homelab"`.
- **Log parsing**: Zeek panels use `| json | line_format "{{.log}}" | json` to unwrap nested JSON.
- **Template variables**: DNS & Traffic dashboards use `$device_ip` for per-device filtering.
- **Dashboard JSON**: Grafana schema v39 — no `__inputs` or `__requires` (repo is source of truth, not “import package”).

## node_exporter

Runs as **systemd on Proxmox hosts**, not in Docker (`/proc`, `/sys`, ZFS). Deploy with `scripts/deploy-node-exporter.sh`. Alloy scrapes `192.168.139.8:9100` and `192.168.139.7:9100` by default — update [`alloy/config.alloy`](alloy/config.alloy) if your IPs differ.

## Collection model: central pull vs. host-local push

Two ways node_exporter metrics reach Mimir, both with identical labels (`job="node"`, `instance="<host>"`) so dashboards don't care which is used:

- **Central pull** — the LXC 105 Alloy scrapes the host's `:9100` (a target in `prometheus.scrape "node"`).
- **Host-local push** (the standardized model) — the host runs its own Alloy that scrapes `localhost:9100` and `remote_write`s at 15s. Deploy with `scripts/deploy-alloy.sh <instance>`; the host config is embedded in that script and secrets live in a `0600 /etc/default/alloy` (never git).

**Never both for one host** — that double-counts series. Moving a host to push ⇒ delete it from the central `prometheus.scrape "node"` block. Rollout target: neptune + all five Proxmox nodes on push; HAOS stays on the central HA `/api/prometheus` scrape (locked appliance, no system Alloy). neptune currently has a tighter 15s `node_neptune` central block as an interim step until its push agent lands.

## Metrics / probes (Alloy)

Blackbox targets and HA scrape mirror the old Prometheus jobs: ICMP to key LAN IPs, HTTP to Home Assistant, bearer token from `alloy/ha_token`. Probe list lives in [`alloy/config.alloy`](alloy/config.alloy) (`prometheus.exporter.blackbox` targets + `prometheus.scrape` blocks).

## Loki query patterns

```logql
{log_source="zeek_dns"} | json | line_format "{{.log}}" | json | __error__=""
```

Metric panels use `count_over_time`, `rate`, `sum_over_time` (with `unwrap` where needed).

## Office display (kiosk)

Self-hosted anonymous Viewer URLs **no longer apply**. Use **public dashboard sharing** for `firewalla-office-display` (see README § “Office display”). The dashboard mixes Mimir + Loki panels. Prometheus queries use the **friendly label scheme Alloy publishes** — `instance="pve"` / `"pve2"` for `node_exporter`, and `job="integrations/blackbox/<target_name>"` (e.g. `firewalla`, `pve`, `pve2`, `neptune`, `ap-office`, `homeassistant-icmp`, `homeassistant-http`, `alloy`, `grafana-cloud`) for blackbox probes. The target IP/URL lives in the Alloy config, not in the dashboard query — if a target moves, edit `alloy/config.alloy` (no dashboard change needed). If the target is renamed, update the dashboard's job-label match.

Playlist URLs on self-hosted Grafana are obsolete; use Cloud playlists or a single public dashboard URL.

## Deploying the central Alloy config

The Alloy on the grafana-stack LXC is **gitops-managed** — do NOT hand-edit the config on the box. Merge to `main`; `alloy-gitops.timer` (every 5 min) pulls, validates with `alloy fmt`, and reloads on drift (`SIGHUP` for `alloy/` changes via the `./alloy` **directory** mount; `docker compose up -d` for compose changes). Force a deploy: `systemctl start alloy-gitops.service` on the LXC. Bootstrap + ops: [`alloy-host/README.md`](alloy-host/README.md). (History: the box used to run a hand-copied, non-git config dir + single-file mounts, so reloads silently read stale inodes — fixed by the dir mount + this loop.)

**Exception — the worker transcript shipper is NOT gitops-managed.** [`alloy/runner-transcript.alloy`](alloy/runner-transcript.alloy) runs as `alloy-transcript.service` on each bullpen *worker* (claude-runner, -2, -3, -4, -5 on pve4), not the LXC, and ships the live fleet reasoning stream (`job="claude_transcript"`) to Cloud Loki. It is deployed by **re-running** [`scripts/deploy-runner-transcript-alloy.sh`](scripts/deploy-runner-transcript-alloy.sh) on each worker — editing the file on `main` does **not** auto-deploy. Egress is deliberately scrubbed (text + tool names only; no `thinking`, no tool inputs, no `user`/tool-result lines) — see #71.

## Testing changes

- Validate dashboard JSON: `python3 -m json.tool dashboards/<file>.json > /dev/null`
- Validate Alloy syntax: `alloy fmt /path/to/config.alloy` (with Alloy binary) or rely on `docker compose` logs after deploy
- Deploying dashboard edits: **merging to `main` auto-applies** via the `terraform` workflow's `apply` job (GitHub OIDC → S3 state in solidago's bucket; no Grafana container restart). Out-of-band you can still `cd terraform && terraform plan && terraform apply` locally — same S3 backend. See [`terraform/README.md`](terraform/README.md) § CI.

## Live dashboard edits — anti-drift rule

Because merging to `main` auto-applies `dashboards/*.json` (see above), **the
repo is the only durable home for dashboard state. Never edit a live dashboard
— Grafana UI, HTTP API, or `mcp__grafana__update_dashboard` — without landing
the identical change in `dashboards/*.json` in the same session** (PR opened
and auto-merge armed before the session ends). A live-only edit survives
exactly until the next merge to `main`, *any* merge: the terraform apply job
re-pushes repo state and silently reverts it.

Corollaries:

- **Live-ahead-of-repo state is a fire, not a curiosity.** If panel titles in
  Grafana don't match the repo JSON, someone's un-codified work is one merge
  away from destruction — recover it into a PR *before* merging anything else
  to this repo.
- **Recovery path**: Grafana keeps dashboard version history. `GET
  /api/dashboards/uid/<uid>/versions` to find the lost version, `GET
  .../versions/<n>` → take `.data`, `del(.id, .version)`, and normalize
  datasource UIDs back to the repo placeholders (`loki`, `prometheus`,
  `infinity`) that `terraform/locals.tf` rewrites at apply time.
- Note the MCP server authenticates as the same `terraform-iac` service
  account as CI, so Grafana's version history cannot distinguish a live MCP
  edit from a terraform apply — don't rely on `createdBy` to spot drift.

Origin: 2026-07-03 — the infra-health fleet-scoreboard revamp was pushed live
via the API but never committed; five unrelated bug-fix merges each ran the
apply and reverted it (restored in #119 from version history).

## Contributing / PRs

PR workflow + auto-merge arming protocol is fleet-wide; see `~/repos/CLAUDE.md`.
