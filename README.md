# drosera

[![Ask DeepWiki](https://deepwiki.com/badge.svg)](https://deepwiki.com/lentago/drosera)

**Drosera** (sundew — the botanical codename line alongside `lentago`,
`solidago`, and `kalmia`) is the Lentago Labs observability suite. Today it
watches the Lentago lab and renders AWS telemetry from the Lentago cloud
estate (Solidago) on demand via a live CloudWatch datasource; deeper AWS
ingestion is the next scope expansion. Renamed from `homelab-observability` on
2026-07-04 —
AWS-side resource names (the OIDC CI role, the Terraform state key) keep the
old prefix, as do the live `/opt/homelab-observability` checkouts on hosts.

**Authorship:** The Terraform, Alloy config, dashboards, scripts, and documentation in this repo are co-written with [Claude](https://claude.ai) (Anthropic). I direct the work and review the output; Claude writes the code. I'm an infrastructure operator, not a software engineer — please don't read this repo as a portfolio of coding ability.

**Agents / contributors:** setup, architecture, and credentials are documented here. Conventions (LogQL, dashboard UIDs, `node_exporter` model, kiosk) are in [CLAUDE.md](CLAUDE.md); PR norms in [CONTRIBUTING.md](CONTRIBUTING.md).

Git-driven observability for a Firewalla home network, powered by [Grafana
Cloud](https://grafana.com/products/cloud/) (free tier) on the visualization
side. Ingestion is per-host, not a single chokepoint: each host runs its own
[Grafana Alloy](https://grafana.com/docs/alloy/) agent and pushes metrics
straight to Cloud (`remote_write`, 15s); a central Alloy on the LXC covers
what's left over — blackbox probes, the Home Assistant scrape, and one Loki
receiver (see [Architecture](#architecture) below).

Everything is declarative:

- Dashboards live as JSON in [`dashboards/`](dashboards/).
- Cloud-side resources (the `Lentago` folder, dashboards, datasources, alert
  rules, contact points) are managed by [Terraform](terraform/) with the
  [`grafana/grafana`](https://registry.terraform.io/providers/grafana/grafana/latest) provider.
- Central (LXC) ingestion is a single declarative
  [`alloy/config.alloy`](alloy/config.alloy) spun up by `docker compose`;
  per-host push agents run from the config embedded in
  [`scripts/deploy-alloy.sh`](scripts/deploy-alloy.sh).

## Architecture

Node metrics **push** from each host (host-local Alloy → Mimir, 15s); the
central Alloy on the LXC handles blackbox probes, the Home Assistant scrape,
and a Loki receiver used only by the device-inventory feed (see below).
Zeek/ACL logs bypass the central Alloy entirely — the Firewalla's Fluent Bit
shipper (owned by [lentago/betula](https://github.com/lentago/betula)) pushes
those directly to Grafana Cloud Loki. **Full rendered diagram, paths, and
label conventions: [docs/metrics-flow.md](docs/metrics-flow.md).**

```
  HOSTS ×6 (neptune, pve, pve2, pve3, pve4, pve5)
    each: node_exporter:9100 → local Alloy ── remote_write 15s ─┐
                                                                ├─▶ Grafana Cloud
  CENTRAL ALLOY (LXC 105)                                       │    (lentago)
    blackbox ICMP/HTTP ───────────────── remote_write ─────────┤    ├─ Mimir (metrics)
    Home Assistant /api/prometheus → HA scrape → remote_write ──┤    ├─ Loki  (logs)
    device_inventory publisher → Loki receiver :3100 ──────────┘    └─ Grafana
                                                                          │
  Firewalla Fluent Bit (Zeek/ACL) ── direct Loki push, no relay ─────────┤
                                                                          │
  AWS / SOLIDAGO CloudWatch ◀── query-on-demand (assume-role) ── Grafana ─┤
                                                                          │
                                                  public share ──▶ Office Display
```

## Loki output contract

Firewalla's Fluent Bit shipper pushes Zeek/ACL logs **directly** to Grafana
Cloud Loki over HTTPS — no LAN relay, and the central Alloy on LXC 105 is not
in this path. It attaches the `cluster="lentago-lab"` label itself (a static
`Labels` directive in its Fluent Bit config), unlike the metrics side, where
the central Alloy's `external_labels` injects that label.

The four active log streams, keyed by `log_source`:

| `log_source` | Contents |
|---|---|
| `zeek_dns` | DNS query/response records from Zeek — domain, query type, client IP, answer. |
| `zeek_conn` | TCP/UDP connection summaries — src/dst IP and port, bytes, duration, state. |
| `zeek_ssl` | TLS handshake records — SNI, certificate subject, cipher, validation status. |
| `firewalla_acl` | Firewalla ACL alarm events — blocked/allowed flows, rule name, severity. |

**Change coordination:** the Firewalla side of this pipeline — the Fluent Bit
config, its direct-to-Loki output block, and the `log_source` label scheme —
lives in [lentago/betula](https://github.com/lentago/betula) (renamed from
`firewalla-axiom-pipeline` 2026-07-04; betula#82, merged 2026-07-09, also
dropped its former parallel Axiom output, so Grafana Cloud Loki is now its
sole destination). Any change to the `log_source` values or the Loki output
must be coordinated with that repo (see its issue #42, which shipped the
current label scheme) so both sides stay in sync.

**Triage pointer:** if Zeek/ACL dashboards go dark, look on the Firewalla /
betula side first (the Fluent Bit container, its Loki output config, box
network egress) — the central Alloy on LXC 105 no longer relays this traffic,
so it's not a suspect for these four streams. It remains the right place to
look for `device_inventory` gaps (below) and for the metrics pipeline.

## Alerting

Terraform provisions the stack's alerting end to end —
[`terraform/alerts.tf`](terraform/alerts.tf): **12 rules** across two rule
groups in the `Lentago` folder, plus the stack's first contact point. See
[docs/adr/0001-grafana-native-alerting-for-site-probes.md](docs/adr/0001-grafana-native-alerting-for-site-probes.md)
for why this lives in Grafana instead of AWS.

- **`Site probe alerts`** (8 rules — "Site down" on `probe_success` and "TLS
  cert expiring" on `probe_ssl_earliest_cert_expiry` under a 21-day threshold,
  for each of the 4 site dashboards). These metrics come from the lab Alloy's
  blackbox exporter and exist nowhere in CloudWatch, so Solidago's AWS-native
  alerting (CloudWatch alarms → SNS, solidago ADR-0001) can't see them.
  `no_data_state = "NoData"` deliberately: the probes run from one lab vantage
  point, so a lab/WAN outage looks identical to a real site outage, and
  alerting on NoData would misfire on every lab hiccup instead of a real one.
- **`Loki ingest absence`** (4 rules — one each for `zeek_dns`, `zeek_conn`,
  `firewalla_acl`, `device_inventory`): fires when a stream goes quiet longer
  than its expected cadence (30m for the two high-volume Zeek streams, 2h for
  the event-driven ACL stream, 3h for the hourly device-inventory cron).
  `no_data_state = "Alerting"` here — the opposite of the probe rules — because
  an empty Loki result *is* the failure this group exists to catch, not an
  ambiguous vantage-point gap.
- **Contact point:** one email contact point (`Site probe email`). The
  recipient is `TF_VAR_alert_email`, a sensitive Terraform variable with no
  default, supplied via CI/`.envrc` and never committed (this is a public
  repo). Routing is scoped per-rule, so it doesn't touch the stack's root
  notification policy.

## Solidago (AWS) contract

Solidago platform metrics render in this stack via a **query-on-demand
CloudWatch datasource** — nothing is streamed or imported into Mimir, so it
consumes zero free-tier active series. Queries bill as CloudWatch
`GetMetricData` at render time; the dashboard refresh floor is **1m**.

- **This repo owns:** the `solidago-cloudwatch` datasource
  (`terraform/datasources.tf`, "Grafana Assume Role" auth) and the Solidago
  dashboards (`dashboards/solidago-platform-health.json`, titled
  `Solidago — Platform Health`).
- **Per-site dashboards** sit in the same flat `Lentago` folder, titled
  `Sites — <domain>`
  (`dashboards/site-*.json`, uid = site repo name): outside-in blackbox
  probes (Mimir) on top, per-TargetGroup / per-ECS-service CloudWatch below.
  ALB panels use SEARCH expressions on stable name fragments — TargetGroup
  and LoadBalancer dimension hashes rotate on the nightly DR rebuild, so
  pinned dimension values break every night. Site dashboards refresh at 5m
  (not the 1m floor) since they're viewed on demand, not kiosked.
  Onboarding a new site: one probe target in `alloy/config.alloy`, one JSON,
  one `sites_dashboards` entry — existing sites untouched.
- **[lentago/solidago](https://github.com/lentago/solidago) owns:** the IAM
  role `solidago-dev-grafana-cloudwatch` (`modules/grafana-cloud`), its trust
  and permission policies, and the External ID plumbing.
- **Coordination rule:** renaming the role, changing auth, or widening its
  policy is a **cross-repo change** — same discipline as the `log_source`
  label contract above.
- **Overnight gaps are the DR drill, not an outage:** solidago tears down and
  rebuilds nightly; role ARNs are deterministic, so the datasource never needs
  re-pointing, and "No data" while the platform is down is correct behavior.
- **Alerting stays AWS-native** (CloudWatch alarms → SNS; solidago ADR-0001) —
  Grafana is visualization only.
- **Known health-check quirk:** the datasource's Save & test / health endpoint
  probes CloudWatch **Logs** as well as metrics, so it reports
  `AccessDeniedException … logs:DescribeLogGroups` alongside "Successfully
  queried the CloudWatch metrics API". That is **expected, not a fault** — the
  role is metrics-only by design (logs belong to Axiom/betula, per ADR-0001's
  boundary). Metrics green = healthy. Verified end-to-end 2026-07-04
  (assume-role query returned live ALB series for all three target groups).

## Repo layout

```
.envrc.example                 # template for direnv — copy to .envrc, fill in secrets
docker-compose.yml             # spins up Alloy on the LXC (one service)
alloy/
  config.alloy                 # Alloy collector config (scrape + push + receive)
  blackbox.yml                 # blackbox prober module definitions
  ha_token.example             # template; real ha_token is gitignored
alloy-host/                    # gitops deploy for the central Alloy on the LXC
  gitops-pull.sh               # 5-min pull + validate + reload-on-drift
  alloy-gitops.{service,timer} # systemd units (bootstrap-only)
  README.md                    # bootstrap + ops
dashboards/                    # source of truth for Grafana dashboard JSON
  network-overview.json
  dns-security.json
  traffic-devices.json
  infra-health.json
  office-display.json
  neptune-nas.json             # Neptune NAS real-time activity (CPU/disk/net/RAID/temps)
  solidago-platform-health.json # Solidago (AWS) via the CloudWatch datasource
  site-*.json                  # per-site health (Mimir probes + per-TG/service CloudWatch)
terraform/                     # manages Cloud-side resources
  *.tf                         # incl. datasources.tf (solidago-cloudwatch) and
                                # alerts.tf (site probe + Loki ingest-absence alert rules)
docs/adr/                      # architecture decision records (e.g. native alerting for site probes)
scripts/
  inventory-cloud.sh           # snapshot current state of lentago.grafana.net
  deploy-node-exporter.sh      # install node_exporter on a host
  deploy-alloy.sh              # install a host-local Alloy push agent (15s remote_write)
.github/workflows/
  terraform.yml                # fmt/validate/plan on PR
```

## First-time setup

### 1. Grafana Cloud credentials

- **Stack service account** (drives Terraform + future CLI tooling). In
  `https://lentago.grafana.net` → **Administration → Users and access → Service
  accounts**, create a service account named `terraform-iac` with role **Admin**,
  then **Add token** and copy the value. This becomes `GRAFANA_AUTH`.
- **Access policy tokens** (drive Alloy remote_write / log push). At
  `https://grafana.com` → **My Account → Access Policies**, create one policy
  with scopes **`metrics:write`** and **`logs:write`** for the `lentago` stack.
  Generate a token; copy the **username** (a numeric stack ID per signal type)
  and **token** and the **push URLs** from the stack details page.

Drop all of the above into `.envrc`:

```bash
cp .envrc.example .envrc
$EDITOR .envrc           # fill in real values
direnv allow
```

### 2. Terraform — adopt Cloud-side resources

```bash
cd terraform
terraform init
terraform plan           # should show: import the Lentago folder + 5 dashboards, then update them
terraform apply
```

State lives in S3 (solidago's `solidago-tfstate-365184644049` bucket, versioned +
encrypted) — no local-state backup step needed. Day to day you don't run `apply`
by hand at all: **merging dashboard/terraform changes to `main` auto-applies** via
the `terraform` workflow. See [terraform/README.md](terraform/README.md) § State and
§ CI.

The first apply rewrites datasource UIDs in each dashboard from `loki` /
`prometheus` (the old self-hosted UIDs) to `grafanacloud-lentago-logs` /
`grafanacloud-lentago-prom` (the lentago stack's auto-provisioned UIDs).
The original JSON files in `dashboards/` are not modified — the rewrite happens
in-memory at apply time via `replace()` in `terraform/locals.tf`.

### 3. Delete orphan datasources in Cloud

The Cloud migration wizard created `loki` and `prometheus` datasources pointing
at the self-hosted LXC, which Grafana Cloud cannot reach. After `terraform
apply` repoints dashboards to `grafanacloud-*`, delete the orphans:

```bash
for uid in loki prometheus; do
  curl -sS -X DELETE \
    -H "Authorization: Bearer $GRAFANA_AUTH" \
    "$GRAFANA_URL/api/datasources/uid/$uid"
done
```

### 4. Alloy on the Proxmox LXC

```bash
# On the LXC (or any host with docker), in this repo:
cp alloy/ha_token.example alloy/ha_token
$EDITOR alloy/ha_token             # paste your HA long-lived access token (no trailing newline — use printf '%s' "<token>" > alloy/ha_token to be safe)
docker compose up -d
docker compose logs -f alloy       # confirm "remote_write succeeded" etc.
open http://<lxc-ip>:12345         # Alloy debug UI
```

After Alloy is up:

- Confirm logs arrive in Cloud: **Explore → grafanacloud-lentago-logs** → `{cluster="lentago-lab"}`.
- Confirm metrics arrive: **Explore → grafanacloud-lentago-prom** →
  `up{cluster="lentago-lab"}` should return 1 for each scrape target.
- Visit a dashboard (e.g. **Lentago / Lentago Lab — Network Overview**) and
  confirm panels render data.

### 5. Office display (kiosk)

Grafana Cloud doesn't allow anonymous viewers. Use **public dashboard sharing**:

1. Open `firewalla-office-display` in the Cloud UI.
2. **Share → Public dashboard → Enable**.
3. Copy the public URL and point the kiosk Chromium at it.

The public URL bypasses auth for that one dashboard only; nothing else in the
stack is exposed.

### 6. CI

Add **repository** secrets (Settings → Secrets and variables → **Actions**,
not Dependabot) so the `plan` and `apply` jobs can authenticate to Grafana:

- `GRAFANA_URL` — full stack URL, e.g. `https://lentago.grafana.net` (no
  trailing slash).
- `GRAFANA_AUTH` — the same Grafana Cloud **service account token** you use in
  `.envrc` as `GRAFANA_AUTH` / `GRAFANA_SA_TOKEN`.

Both must be non-empty. If either is missing, the job fails immediately with a
clear log message instead of a misleading Terraform provider error.

AWS (for the S3 state backend) is reached via GitHub **OIDC** — no AWS secrets are
stored; the jobs assume `homelab-observability-github-actions-terraform` in account
`365184644049`. The workflow runs `fmt -check` + `validate` + `plan` (posted as a PR
comment) on every PR touching `terraform/**` or `dashboards/**`, and **`apply
-auto-approve` on push to `main`** — so merges deploy automatically. See
[terraform/README.md](terraform/README.md) § CI.

## Day-to-day

### Edit a dashboard

1. Edit the JSON file in `dashboards/` (or edit in the Cloud UI and copy the
   exported JSON back into the file).
2. Open a PR — CI posts the `terraform plan` as a comment. **Merging to `main`
   auto-applies.** (Out-of-band you can still `cd terraform && terraform apply`.)

### Add a new dashboard

1. Drop a new JSON file in `dashboards/`. Title it `<Group> — <What>`
   (`Lentago Lab — …`, `Claytonia — …`, `Solidago — …`, `Sites — <domain>`):
   every dashboard lives in one flat `Lentago` folder, so the title prefix is
   the only thing that groups the list.
2. Add an entry to the matching per-group local (`lab_dashboards`,
   `claytonia_dashboards`, `solidago_dashboards`, or `sites_dashboards`) in
   [`terraform/locals.tf`](terraform/locals.tf). These maps differ in how the
   JSON is pre-processed, not in where the dashboard lands.
3. Open a PR; merging to `main` applies it (or `terraform apply` locally).

### Add new scrape targets / new log sources

Edit [`alloy/config.alloy`](alloy/config.alloy), open a PR, merge. The central
Alloy on the grafana-stack LXC is **gitops-managed**: `alloy-gitops.timer`
pulls `origin/main` every 5 minutes, validates with `alloy fmt`, and reloads the
collector on drift (`SIGHUP` for `alloy/` changes, `docker compose up -d` for
compose changes). No hand-editing on the LXC — see
[`alloy-host/README.md`](alloy-host/README.md). To deploy immediately instead of
waiting for the timer: `systemctl start alloy-gitops.service` on the LXC.

### node_exporter

Bare-metal node_exporter on each host is the metric source. Run
`scripts/deploy-node-exporter.sh` against any new host you add. How those
metrics reach Grafana Cloud depends on the collection model below.

### Collection models: central pull vs. host-local push

There are two ways a host's node_exporter metrics get to Mimir, and the repo
supports both side by side with identical labels (`job="node"`,
`instance="<host>"`), so dashboards never care which is in use:

- **Central pull (default/legacy):** the Alloy on LXC 105 scrapes the host's
  `:9100` over the LAN. Add the host to the `prometheus.scrape "node"` target
  list in [`alloy/config.alloy`](alloy/config.alloy).
- **Host-local push (standardized):** the host runs its own Alloy that scrapes
  `localhost:9100` and `remote_write`s to Mimir at 15s. Tighter cadence,
  buffers across network blips, and each host owns its own shipping. Deploy
  with [`scripts/deploy-alloy.sh`](scripts/deploy-alloy.sh):

  ```bash
  source .envrc                     # exports GRAFANA_CLOUD_METRICS_*
  # on the target host (root, or via sudo):
  ./deploy-alloy.sh <instance-label>   # e.g. neptune, pve, pve3
  ```

  The script installs Alloy from the Grafana apt repo, writes
  `/etc/alloy/config.alloy` (canonical config embedded in the script) and a
  `0600 /etc/default/alloy` holding the push token, then enables the service.

**Don't run both for the same host** — that double-counts series. When you move
a host to push, delete it from the central `prometheus.scrape "node"` block.
The rollout target is neptune + all five Proxmox nodes on push; HAOS stays on
the central HA `/api/prometheus` scrape (it can't run a system Alloy).

### Fleet reasoning stream (worker transcripts)

The **Claytonia — Runner Fleet** dashboard has a live *"Fleet stream of
consciousness"* panel that shows each running bullpen job's reasoning in
near-real-time (each assistant turn's narration + the tools it fired). The
source is a **worker-local Alloy agent** on each runner that tails Claude
Code's session transcript as it is written and ships it to Grafana Cloud Loki
as `job="claude_transcript"` (labels: `project`, `worker`, `session_id`).

Deploy it per worker with
[`scripts/deploy-runner-transcript-alloy.sh`](scripts/deploy-runner-transcript-alloy.sh)
(canonical config: [`alloy/runner-transcript.alloy`](alloy/runner-transcript.alloy)):

```bash
source .envrc   # exports GRAFANA_CLOUD_LOGS_*
# on the worker (sudo-capable), from a repo checkout:
./scripts/deploy-runner-transcript-alloy.sh   # worker label is auto (from hostname)
```

It runs as a dedicated `alloy-transcript.service` under the `claude` user (the
session files are `0600 claude:claude`). **Egress is deliberately scrubbed**
(see [#71](https://github.com/lentago/drosera/issues/71)): only
`assistant` text + tool *names* are shipped — `thinking` blocks, tool *inputs*,
and `user`/tool-result lines (raw repo contents) never leave the LAN. A `runid`
label is a possible future bullpen-side fast-follow.

### Device inventory feed (name ↔ IP resolution)

Dashboards that show raw LAN source IPs (`id_orig_h`) resolve them to device
names by joining against a **device-inventory log stream**,
`log_source="device_inventory"`. Grafana Cloud runs queries server-side and
cannot reach the LAN, and LAN topology must not be published to GitHub — so the
name↔IP mapping travels the trusted central-Alloy → Cloud Loki channel (see
[#113](https://github.com/lentago/drosera/issues/113)). **This publisher is the
one remaining user of the central Alloy's `:3100` Loki receiver**
(`loki.source.api "firewalla"` in [`alloy/config.alloy`](alloy/config.alloy));
Zeek/ACL logs no longer travel this path (see "Loki output contract" above) —
don't mistake the receiver block for dead config and remove it.

The publisher
([`scripts/device-inventory-publisher/publish-device-inventory.sh`](scripts/device-inventory-publisher/publish-device-inventory.sh))
runs **on the Firewalla box** (pi user, **hourly** via cron). It reads the box's
own device inventory from local redis (`host:mac:*` hashes — no new
credentials) and pushes one record per (device, IP) pair to the central Alloy
Loki receiver (`http://<ALLOY_HOST>:3100/loki/api/v1/push`).

**Stream schema** — one Loki stream per (device, IP):

| Field | Value |
|---|---|
| label `log_source` | `device_inventory` |
| label `dev` | `<name>\|<ip>` — **load-bearing** (see below) |
| line body (JSON) | `{"name":"…","ip":"…","mac":"…","family":"4"\|"6","source":"firewalla-redis"}` |

Display name is the redis `name` field, else `bname`, else the MAC. Both the
IPv4 (`ipv4Addr`) and every IPv6 (`ipv6Addr` array) address get their own row.

**The `dev` label contract:** the `<name>|<ip>` shape lets a dashboard build a
template variable with `label_values({log_source="device_inventory"}, dev)` and
regex `/(?<text>[^|]+)\|(?<value>.+)/` — the dropdown shows device *names* while
the variable value stays the raw IP that `id_orig_h=~"$device_ip"` needs. Any
`|` in a device name is stripped before composing the label so the split stays
unambiguous.

Deploy / update it by **re-running** the deploy script from the operator
workstation (it scp's the publisher, installs the pi cron entry, and installs a
`~/.firewalla/config/post_main.d/` hook that re-installs the cron after FireMain
regenerates state):

```bash
./scripts/deploy-device-inventory-publisher.sh <ALLOY_HOST>   # e.g. 192.168.139.20
# smoke-test on the box without pushing:
ssh pi@firewalla.local 'DRY_RUN=1 ~/.firewalla/run/device-inventory/publish-device-inventory.sh | head'
```

Like the worker transcript shipper, this publisher is **not gitops-managed** —
editing the script on `main` does not auto-deploy; you must re-run the deploy
script. Volume is negligible (~110 devices, hourly; logs not metrics, so it
does not touch the 15k active-series cap).

### Series budget / HA export trim

Grafana Cloud free tier caps **active series at 15,000**. Home Assistant's
`/api/prometheus` export is the single biggest consumer — it emits a series
for nearly every entity plus per-entity change-counters, "last updated"
timestamps, availability flags, and `*_created` markers. None of that is used
by any dashboard, so the `prometheus.relabel "ha_trim"` component in
[`alloy/config.alloy`](alloy/config.alloy) drops those families before
remote_write, reclaiming ~5.8k series. The real numeric HA metrics
(temperatures, fan RPM, battery, climate, brightness, sensor states) are kept.

Check current usage with the `grafanacloud-usage` datasource:
`grafanacloud_instance_active_series`. If you add a host (each node_exporter is
~1.3k series), watch the headroom — trim more (e.g. node_exporter discard/flush
families) or the rollout will hit `err-mimir-max-active-series`.

### Check Loki label health

`scripts/check-loki-labels.sh` queries Loki for active `log_source` values over
the last 24h and diffs against the expected set (`zeek_dns`, `zeek_conn`,
`zeek_ssl`, `firewalla_acl`).  Run it manually as a sanity check, or wire it to
a cron / GitHub Actions schedule to alert on silent log streams:

```bash
source .envrc
./scripts/check-loki-labels.sh
```

Exits 0 when all four values are present; exits 1 and prints the missing names to
stderr otherwise.

## Why this layout

The original incarnation of this repo ran Loki, Prometheus, Grafana, and
blackbox-exporter all on a single LXC via `docker compose`, with file-based
provisioning. That worked but had three pain points:

1. **Storage on the LXC** — Prometheus TSDB + Loki chunks meant disk pressure
   and another thing to monitor.
2. **Dashboards drifted between repo and UI** — anything edited in the UI was
   lost on the next provisioner reload.
3. **No upgrade story** for Grafana itself — each `docker compose pull` was a
   gamble.

Migrating to Grafana Cloud free tier + Alloy fixes all three: storage moves to
the Cloud's free 50GB logs / 10K active series allotment; Terraform plus
checked-in dashboard JSON makes the repo the source of truth (UI edits get
overwritten on next apply); and Cloud handles Grafana upgrades.

## License

[MIT](LICENSE).

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).
