# Estate status page

A static status page, regenerated on a schedule and published to **GitHub Pages
from this repo** (no new services, free tier). It shows:

1. **Site availability** vs the 99.9% / 30-day SLO, with error-budget remaining,
   queried from the same Grafana Cloud Mimir `probe_success` series the R14
   burn-rate alerts use (`terraform/alerts.tf`, `local.slo_burn_alerts`).
2. **Fleet CI health** — the latest completed `main`-branch workflow conclusion
   per repo, via the GitHub API.
3. A link to the **public incident register** (`lentago/.github`
   `fleet-reports/incidents.md`).

Built by [`build.py`](build.py) (stdlib only — `tomllib` + `urllib`, no pip
install) and deployed by [`.github/workflows/status-page.yml`](../.github/workflows/status-page.yml).

## Degrade gracefully — never fake green

Every data source degrades independently. If the Mimir query fails (or no
credential is configured), a GitHub call fails, or a series is missing, the
affected item renders an explicit neutral **"no data"** state — never a healthy
green one — and the rest of the page still builds. The page makes no correctness
or availability guarantees in its copy.

## Variants — a config file away

The build is variant-agnostic; a variant is **just a TOML config**. Ship-now:

- [`config/estate.toml`](config/estate.toml) — the maintainer-facing estate page
  (wired into the schedule workflow).
- [`config/client-example.toml`](config/client-example.toml) — a client-facing
  "are we open / is it running?" scaffold: plain-language status words, no error
  budgets, no CI section. Reuses `build.py` unchanged. Not yet wired to a Pages
  target; publish it by pointing a build step at it with its own output path.

Adding a site or repo, changing copy, or renaming status words is a one-line
edit in the config — no code change.

## Build locally

```bash
python3 status-page/build.py --config status-page/config/estate.toml --out /tmp/out
# open /tmp/out/index.html
```

With no `GRAFANA_*` / `MIMIR_*` env set, availability renders as "no data"
(expected); CI health still populates from anonymous GitHub reads.

Output (`status-page/public/`, git-ignored): `index.html` plus a machine-readable
`status.json` companion.

## Secrets

The Mimir query needs a credential. The build accepts either pair (see
`resolve_prom_backend` in `build.py`); the workflow's preflight fails fast with
setup instructions if **neither** is configured.

| Preference | Secrets | Notes |
|---|---|---|
| **Recommended (least privilege)** | `MIMIR_QUERY_ENDPOINT` + `MIMIR_QUERY_TOKEN` | A Grafana Cloud Prometheus **query** endpoint (e.g. `https://prometheus-prod-XX.grafana.net/api/prom`) and an access-policy token scoped to `metrics:read`. Token may be `bearer` or `user:secret` (Basic). |
| **Reuse (ships now, no minting)** | `GRAFANA_URL` + `GRAFANA_AUTH` | The existing terraform secrets. Queries Mimir through the Grafana datasource proxy (`/api/datasources/proxy/uid/grafanacloud-prom`). Already present, so the page works with no new secret. |

`GITHUB_TOKEN` is the workflow's default token — the fleet repos read for CI
health are public, so no extra scope is needed.

## Enabling Pages

The workflow deploys via `actions/deploy-pages`. In repo **Settings → Pages**,
set **Source: GitHub Actions** once. Trigger a first build via **Actions →
status-page → Run workflow** (or wait for the `*/30` cron).
