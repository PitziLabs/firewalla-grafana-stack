#!/usr/bin/env python3
"""Generate a static status page from Grafana Cloud Mimir + the GitHub API.

The page is regenerated on a schedule (see .github/workflows/status-page.yml)
and published to GitHub Pages. It renders three, independently-degrading
sections driven entirely by a TOML config file:

  1. Site availability vs the 99.9%/30d SLO + error-budget remaining
     (queried from the same `probe_success` series the R14 burn-rate alerts
     use — see terraform/alerts.tf `local.slo_burn_alerts`).
  2. Per-repo CI health: the latest completed main-branch workflow conclusion
     via the GitHub API.
  3. A link to the public incident register.

DESIGN — parameterized variants. Every user-visible string, the site/repo
lists, and which sections render are config, not code. The "estate" variant
ships now (config/estate.toml); a client-facing "are we open / is it running"
variant is config/client-example.toml — a `--config` away, no code change.

HARD RULE — degrade gracefully, never fake green. Any data source that is
unavailable at build time renders as an explicit neutral "no data" state, never
as a healthy/green one. A failed Mimir query, a failed GitHub call, or a missing
series each produce "no data" for exactly the affected item; the rest of the
page still builds. The page makes no correctness or guarantee claims in copy.

Stdlib only (tomllib + urllib): no pip install in CI.
"""

from __future__ import annotations

import argparse
import html
import json
import os
import sys
import tomllib
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone

HTTP_TIMEOUT = 20  # seconds; a slow source degrades to "no data", never hangs CI


# ---------------------------------------------------------------------------
# HTTP helpers
# ---------------------------------------------------------------------------
def _http_json(url: str, headers: dict[str, str]) -> dict | None:
    """GET a URL and parse JSON. Return None on ANY failure (the caller renders
    "no data"): the page must never fabricate a healthy state from an error."""
    req = urllib.request.Request(url, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError, ValueError) as exc:
        print(f"  ! request failed for {url.split('?')[0]}: {exc}", file=sys.stderr)
        return None


def _auth_header(token: str) -> dict[str, str]:
    """A Grafana/Mimir credential can be a bearer token (`glsa_...`) or a
    `user:secret` basic pair. Pick the right scheme so both existing repo
    secrets and a scoped access-policy token work unchanged."""
    if ":" in token:
        import base64

        b64 = base64.b64encode(token.encode("utf-8")).decode("ascii")
        return {"Authorization": f"Basic {b64}"}
    return {"Authorization": f"Bearer {token}"}


# ---------------------------------------------------------------------------
# Prometheus / Mimir
# ---------------------------------------------------------------------------
class PromClient:
    """Instant-query client for Grafana Cloud Mimir.

    Two backends, chosen by environment (see resolve_prom_backend):
      - direct:  a Prometheus-compatible query endpoint + its own token
                 (MIMIR_QUERY_ENDPOINT / MIMIR_QUERY_TOKEN) — the least-privilege
                 path; the operator can scope a `metrics:read` access policy.
      - proxy:   the Grafana instance datasource proxy, reusing the existing
                 GRAFANA_URL / GRAFANA_AUTH repo secrets — ships with no new
                 secret to mint.
    """

    def __init__(self, base_url: str, headers: dict[str, str]):
        self.base_url = base_url.rstrip("/")
        self.headers = headers

    def query(self, expr: str) -> dict[str, float] | None:
        """Run an instant query; return {job_label: value}. None on failure."""
        url = f"{self.base_url}/api/v1/query?" + urllib.parse.urlencode({"query": expr})
        data = _http_json(url, self.headers)
        if not data or data.get("status") != "success":
            return None
        out: dict[str, float] = {}
        for series in data.get("data", {}).get("result", []):
            job = series.get("metric", {}).get("job")
            value = series.get("value")
            if job is None or not value:
                continue
            try:
                out[job] = float(value[1])
            except (TypeError, ValueError):
                continue
        return out


def resolve_prom_backend(datasource_uid: str) -> PromClient | None:
    """Build a PromClient from the environment, or None if no credential is set.

    Preference order:
      1. MIMIR_QUERY_ENDPOINT + MIMIR_QUERY_TOKEN — a dedicated, scoped,
         read-only query endpoint (recommended least-privilege upgrade).
      2. GRAFANA_URL + GRAFANA_AUTH — reuse the existing terraform secrets via
         the datasource proxy at /api/datasources/proxy/uid/<uid>.
    """
    endpoint = os.environ.get("MIMIR_QUERY_ENDPOINT", "").strip()
    token = os.environ.get("MIMIR_QUERY_TOKEN", "").strip()
    if endpoint and token:
        return PromClient(endpoint, _auth_header(token))

    grafana_url = os.environ.get("GRAFANA_URL", "").strip()
    grafana_auth = os.environ.get("GRAFANA_AUTH", "").strip()
    if grafana_url and grafana_auth:
        base = f"{grafana_url.rstrip('/')}/api/datasources/proxy/uid/{datasource_uid}"
        return PromClient(base, _auth_header(grafana_auth))

    return None


# ---------------------------------------------------------------------------
# Section builders
# ---------------------------------------------------------------------------
def build_availability(cfg: dict) -> dict:
    """Compute per-site availability + error budget from Mimir.

    Returns a dict the template consumes; each site carries an explicit state so
    an unreachable source or a missing series renders "no data", never green.
    """
    sec = cfg.get("availability", {})
    slo = cfg.get("slo", {})
    target = float(slo.get("target", 0.999))
    window_days = int(slo.get("window_days", 30))
    budget_fraction = 1.0 - target  # e.g. 0.001

    sites_cfg = sec.get("sites", [])
    client = resolve_prom_backend(sec.get("datasource_uid", "grafanacloud-prom"))

    # Two batched instant queries cover every site regardless of count: current
    # up/down and the rolling-window availability average.
    current = avail = None
    if client is not None:
        current = client.query("probe_success")
        avail = client.query(f"avg_over_time(probe_success[{window_days}d])")
    else:
        print("  ! no Mimir credential in environment; availability = no data", file=sys.stderr)

    allowed_minutes = window_days * 24 * 60 * budget_fraction

    sites = []
    for s in sites_cfg:
        job = s["job"]
        entry = {
            "name": s["name"],
            "label": s.get("label", s["name"]),
            "url": s.get("url", f"https://{s['name']}"),
            "slo": bool(s.get("slo", True)),
            "note": s.get("note", ""),
            "state": "nodata",  # nodata | up | down
            "availability": None,
            "budget_remaining": None,
            "budget_minutes_remaining": None,
        }

        if current is not None and job in current:
            entry["state"] = "up" if current[job] >= 1.0 else "down"

        if avail is not None and job in avail:
            a = max(0.0, min(1.0, avail[job]))
            entry["availability"] = a
            if entry["slo"] and budget_fraction > 0:
                consumed = (1.0 - a) / budget_fraction
                remaining = max(0.0, 1.0 - consumed)
                entry["budget_remaining"] = remaining
                entry["budget_minutes_remaining"] = allowed_minutes * remaining

        sites.append(entry)

    return {
        "enabled": bool(sec.get("enabled", True)),
        "heading": sec.get("heading", "Site availability"),
        "target": target,
        "window_days": window_days,
        "allowed_minutes": allowed_minutes,
        "source_ok": client is not None and current is not None,
        "sites": sites,
    }


def build_ci(cfg: dict) -> dict:
    """Latest completed main-branch workflow conclusion per configured repo."""
    sec = cfg.get("ci", {})
    repos_cfg = sec.get("repos", [])
    token = os.environ.get("GITHUB_TOKEN", "").strip()
    headers = {"Accept": "application/vnd.github+json", "User-Agent": "drosera-status-page"}
    if token:
        headers["Authorization"] = f"Bearer {token}"

    repos = []
    for r in repos_cfg:
        full = r["name"]  # owner/repo
        branch = r.get("branch", "main")
        entry = {
            "name": full,
            "label": r.get("label", full),
            "url": f"https://github.com/{full}/actions?query=branch%3A{branch}",
            "state": "nodata",  # nodata | ok | fail
            "conclusion": None,
            "workflow": None,
            "updated": None,
            "run_url": None,
        }
        url = (
            f"https://api.github.com/repos/{full}/actions/runs?"
            + urllib.parse.urlencode(
                {"branch": branch, "status": "completed", "per_page": 1, "exclude_pull_requests": "true"}
            )
        )
        data = _http_json(url, headers)
        runs = (data or {}).get("workflow_runs") or []
        if runs:
            run = runs[0]
            conclusion = run.get("conclusion")
            entry["conclusion"] = conclusion
            entry["workflow"] = run.get("name")
            entry["updated"] = run.get("updated_at")
            entry["run_url"] = run.get("html_url")
            entry["state"] = "ok" if conclusion == "success" else "fail"
        repos.append(entry)

    return {
        "enabled": bool(sec.get("enabled", True)),
        "heading": sec.get("heading", "CI health (main branch)"),
        "repos": repos,
    }


# ---------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------
def _pct(x: float | None, digits: int = 2) -> str:
    return "—" if x is None else f"{x * 100:.{digits}f}%"


def _status_label(cfg: dict, key: str, default: str) -> str:
    return cfg.get("status_labels", {}).get(key, default)


def render_html(cfg: dict, avail: dict, ci: dict, generated: datetime) -> str:
    page = cfg.get("page", {})
    title = page.get("title", "Status")
    subtitle = page.get("subtitle", "")
    footer_note = page.get("footer_note", "")
    slo = cfg.get("slo", {})
    show_budget = bool(slo.get("show_error_budget", True))
    show_target = bool(slo.get("show_target", True))

    esc = html.escape
    lbl_up = _status_label(cfg, "operational", "Operational")
    lbl_down = _status_label(cfg, "down", "Down")
    lbl_nodata = _status_label(cfg, "nodata", "No data")
    lbl_ci_ok = _status_label(cfg, "ci_ok", "Passing")
    lbl_ci_fail = _status_label(cfg, "ci_fail", "Failing")

    gen_str = generated.strftime("%Y-%m-%d %H:%M UTC")
    parts: list[str] = []

    parts.append(f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{esc(title)}</title>
<style>
  :root {{
    --bg:#0f1115; --card:#171a21; --line:#262b36; --fg:#e6e9ef; --muted:#9aa4b2;
    --ok:#3fb950; --down:#f85149; --nodata:#6e7681;
  }}
  * {{ box-sizing:border-box; }}
  body {{ margin:0; background:var(--bg); color:var(--fg);
    font:16px/1.5 system-ui,-apple-system,Segoe UI,Roboto,sans-serif; }}
  .wrap {{ max-width:900px; margin:0 auto; padding:2rem 1.25rem 4rem; }}
  header h1 {{ margin:0 0 .25rem; font-size:1.7rem; }}
  header p {{ margin:0; color:var(--muted); }}
  h2 {{ font-size:1.15rem; margin:2.25rem 0 .85rem; }}
  .card {{ background:var(--card); border:1px solid var(--line); border-radius:10px;
    padding:.9rem 1rem; margin:.6rem 0; display:flex; align-items:center;
    gap:1rem; flex-wrap:wrap; }}
  .card .name {{ font-weight:600; flex:1 1 40%; min-width:180px; }}
  .card .name a {{ color:var(--fg); text-decoration:none; }}
  .card .name a:hover {{ text-decoration:underline; }}
  .card .name small {{ display:block; color:var(--muted); font-weight:400; font-size:.82rem; }}
  .metrics {{ display:flex; gap:1.5rem; flex-wrap:wrap; margin-left:auto; }}
  .metric {{ text-align:right; }}
  .metric .v {{ font-variant-numeric:tabular-nums; font-weight:600; }}
  .metric .k {{ display:block; color:var(--muted); font-size:.72rem; text-transform:uppercase;
    letter-spacing:.04em; }}
  .badge {{ display:inline-flex; align-items:center; gap:.45rem; font-weight:600;
    font-size:.9rem; white-space:nowrap; }}
  .dot {{ width:.7rem; height:.7rem; border-radius:50%; display:inline-block; }}
  .ok .dot {{ background:var(--ok); }} .ok {{ color:var(--ok); }}
  .down .dot {{ background:var(--down); }} .down {{ color:var(--down); }}
  .nodata .dot {{ background:var(--nodata); }} .nodata {{ color:var(--nodata); }}
  .bar {{ height:5px; border-radius:3px; background:var(--line); overflow:hidden;
    width:120px; margin-top:.35rem; }}
  .bar > span {{ display:block; height:100%; }}
  .note {{ color:var(--muted); font-size:.9rem; margin:.4rem 0 0; }}
  footer {{ margin-top:3rem; padding-top:1.25rem; border-top:1px solid var(--line);
    color:var(--muted); font-size:.85rem; }}
  footer a, .incident a {{ color:#58a6ff; }}
  .incident {{ font-size:1.05rem; }}
</style>
</head>
<body>
<div class="wrap">
<header>
  <h1>{esc(title)}</h1>
  {f'<p>{esc(subtitle)}</p>' if subtitle else ''}
</header>
""")

    # --- Availability ------------------------------------------------------
    if avail["enabled"]:
        parts.append(f'<h2>{esc(avail["heading"])}</h2>')
        if show_target:
            parts.append(
                f'<p class="note">Target: {avail["target"] * 100:g}% availability over a rolling '
                f'{avail["window_days"]}-day window '
                f'({avail["allowed_minutes"]:.0f} min of allowed downtime per window). '
                f'Measured by outside-in blackbox probes from a single lab vantage point.</p>'
            )
        if not avail["source_ok"]:
            parts.append(
                '<p class="note nodata">Metrics source unavailable at build time — '
                'availability figures below show as no data.</p>'
            )
        for s in avail["sites"]:
            if s["state"] == "up":
                badge = f'<span class="badge ok"><span class="dot"></span>{esc(lbl_up)}</span>'
            elif s["state"] == "down":
                badge = f'<span class="badge down"><span class="dot"></span>{esc(lbl_down)}</span>'
            else:
                badge = f'<span class="badge nodata"><span class="dot"></span>{esc(lbl_nodata)}</span>'

            name_html = f'<a href="{esc(s["url"])}" rel="noopener">{esc(s["label"])}</a>'
            note = f'<small>{esc(s["note"])}</small>' if s["note"] else ""

            metrics = [f'<div class="metric">{badge}<span class="k">status</span></div>']
            av = s["availability"]
            metrics.append(
                f'<div class="metric"><span class="v">{_pct(av)}</span>'
                f'<span class="k">{avail["window_days"]}d avail</span></div>'
            )
            if show_budget and s["slo"]:
                br = s["budget_remaining"]
                if br is None:
                    bar = ""
                    bv = "—"
                else:
                    color = "var(--ok)" if br > 0.25 else ("var(--down)" if br <= 0 else "#d29922")
                    bar = f'<div class="bar"><span style="width:{br * 100:.0f}%;background:{color}"></span></div>'
                    mins = s["budget_minutes_remaining"]
                    bv = f"{br * 100:.0f}%"
                    if mins is not None:
                        bv += f' <span class="k" style="display:inline">({mins:.0f} min)</span>'
                metrics.append(
                    f'<div class="metric"><span class="v">{bv}</span>'
                    f'<span class="k">budget left</span>{bar}</div>'
                )
            parts.append(
                f'<div class="card"><div class="name">{name_html}{note}</div>'
                f'<div class="metrics">{"".join(metrics)}</div></div>'
            )

    # --- CI health ---------------------------------------------------------
    if ci["enabled"]:
        parts.append(f'<h2>{esc(ci["heading"])}</h2>')
        for r in ci["repos"]:
            if r["state"] == "ok":
                badge = f'<span class="badge ok"><span class="dot"></span>{esc(lbl_ci_ok)}</span>'
            elif r["state"] == "fail":
                concl = esc(r["conclusion"] or "failing")
                badge = f'<span class="badge down"><span class="dot"></span>{esc(lbl_ci_fail)} ({concl})</span>'
            else:
                badge = f'<span class="badge nodata"><span class="dot"></span>{esc(lbl_nodata)}</span>'
            link = r["run_url"] or r["url"]
            wf = f'<small>{esc(r["workflow"])}</small>' if r["workflow"] else ""
            when = ""
            if r["updated"]:
                when = f'<div class="metric"><span class="v" style="font-weight:400">{esc(r["updated"][:10])}</span><span class="k">last run</span></div>'
            parts.append(
                f'<div class="card"><div class="name">'
                f'<a href="{esc(link)}" rel="noopener">{esc(r["label"])}</a>{wf}</div>'
                f'<div class="metrics"><div class="metric">{badge}<span class="k">latest main run</span></div>{when}</div>'
                f'</div>'
            )

    # --- Incidents ---------------------------------------------------------
    inc = cfg.get("incidents", {})
    if inc.get("enabled", True) and inc.get("url"):
        parts.append(f'<h2>{esc(inc.get("heading", "Incidents"))}</h2>')
        parts.append(
            f'<p class="incident">→ <a href="{esc(inc["url"])}" rel="noopener">'
            f'{esc(inc.get("label", "Public incident register"))}</a></p>'
        )

    # --- Footer ------------------------------------------------------------
    parts.append(
        f'<footer><p>Generated {esc(gen_str)}. Rebuilt automatically on a schedule; '
        f'figures may lag live conditions. A <span class="nodata">no&nbsp;data</span> state means the '
        f'underlying source was unavailable when this page was built.</p>'
    )
    if footer_note:
        parts.append(f'<p>{esc(footer_note)}</p>')
    parts.append("</footer></div></body></html>")

    return "\n".join(parts)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--config", required=True, help="path to a variant TOML config")
    ap.add_argument("--out", default="status-page/public", help="output directory")
    args = ap.parse_args()

    with open(args.config, "rb") as fh:
        cfg = tomllib.load(fh)

    print(f"Building '{cfg.get('variant', '?')}' variant from {args.config}", file=sys.stderr)

    generated = datetime.now(timezone.utc)
    avail = build_availability(cfg)
    ci = build_ci(cfg)

    html_out = render_html(cfg, avail, ci, generated)

    os.makedirs(args.out, exist_ok=True)
    index_path = os.path.join(args.out, "index.html")
    with open(index_path, "w", encoding="utf-8") as fh:
        fh.write(html_out)

    # Machine-readable companion (handy for the client "is it running?" variant
    # and for debugging what the page saw at build time).
    data_path = os.path.join(args.out, "status.json")
    with open(data_path, "w", encoding="utf-8") as fh:
        json.dump(
            {"generated": generated.isoformat(), "variant": cfg.get("variant"),
             "availability": avail, "ci": ci},
            fh, indent=2,
        )

    print(f"Wrote {index_path} and {data_path}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
