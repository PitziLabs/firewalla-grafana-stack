# ADR-0005: Series-budget engineering under the free-tier active-series cap

**Status:** Accepted (2026-06-10 onward; reconstructed 2026-08-13)

## Context

The Grafana Cloud free tier (ADR-0002) meters **active metric series**, and
that cap is a hard ceiling the whole metrics design has to live under. (The cap
figure appears two ways in this repo: the series-budget issues #52/#138/#167
size their work against a **15k** budget, while the README's "Why this layout"
migration note cites the tier's **10K active series** allotment. Either way the
operative point is the same — series are scarce and every source competes for
the same finite pool.) Unlike storage or query cost, series count is not
something you can defer; blow the cap and ingestion for new series stops. So the
recurring engineering question in this repo is: for each telemetry source, is it
worth its series, and if it is a metric at all.

## Decision

Treat active series as a managed budget, and shape each source to spend as
little of it as possible:

- **Trim noisy exporters at the source.** The Home Assistant export was trimmed
  to reclaim roughly 5.8k active series (PR #52, 2026-06-10) — HA emits a large
  number of low-value series by default, so the export is filtered rather than
  ingested whole.
- **Drop useless node_exporter series with relabel rules.** `metric_relabel`
  drop rules cut node_exporter series for about 1k of headroom under the cap
  (issue #138 → PR #167, "Trim node-exporter series with metric_relabel drop
  rules", merged 2026-07-20).
- **Make inherently high-cardinality data a log stream, not metrics.** The
  device name↔IP inventory is published as a Loki log stream
  (`log_source="device_inventory"`), *not* as metric series — deliberately, so
  ~110 devices cost zero active series and land against the free logs allotment
  instead (issue #113 plan → PR #122, "device-inventory: Firewalla redis → Loki
  publisher", merged 2026-07-03). The privacy dimension of that same choice is
  ADR-0006; here the driver is the series budget.
- **Query AWS telemetry on demand instead of ingesting it.** Solidago platform
  metrics render through a query-on-demand CloudWatch datasource with **zero
  Mimir series** (issue #132 → PR #133, merged 2026-07-04). Because solidago's
  nightly DR rebuild rotates the TargetGroup/LoadBalancer dimension hashes,
  panels can't pin dimension values — the platform-health dashboard uses wildcard
  dimensions and the site dashboards use CloudWatch SEARCH expressions on stable
  name fragments, so queries survive the nightly rotation. Ingesting these
  metrics into Mimir would have both cost series and broken every night.

## Alternatives

- **Streaming CloudWatch metrics into Mimir (metric-stream / scraping AWS into
  the series budget).** *Recorded, rejected.* It would put AWS metrics on the
  same footing as lab metrics, but every streamed series counts against the
  free-tier cap, and the nightly-rotating dimension hashes would churn series
  constantly. Query-on-demand spends zero series and sidesteps the rotation —
  strictly better here.
- **Ingest everything as-emitted and prune reactively when the cap is hit.**
  *Recorded implicitly, rejected in practice.* This is what the trims (#52,
  #167) exist to undo; letting exporters ingest whole and firefighting the cap
  later is the failure mode, not the plan. The chosen posture is to shape
  sources up front.
- **Pay for a higher Grafana Cloud tier to lift the cap.** *Retrospective — not
  considered at the time.* Worse. It would make the trims and the log-stream /
  query-on-demand choices unnecessary, but it runs directly against the
  free-tier-as-constraint stance that shaped the whole migration (ADR-0002): the
  lab is deliberately built to fit a free tier, so spending money to avoid
  budget engineering trades away the exact constraint the project is here to
  practice under. Cheaper on effort, wrong on principle.

## Consequences

- Every new metric source is a budget question first: can it be a log stream, a
  query-on-demand datasource, or a trimmed export before it becomes ingested
  metric series.
- The series budget is coupled to ADR-0003's never-both rule — a host scraped by
  both central pull and host-local push double-counts, silently eating the same
  budget these trims defend.
- The AWS query-on-demand boundary means "No data" during solidago's nightly DR
  window is correct behaviour, not an outage, and SEARCH/wildcard dimensions
  must be preserved — pinning a dimension value reintroduces the nightly
  breakage.
- The choice to render inventory as logs (this ADR) is the same edit that keeps
  LAN topology out of GitHub and inside the trusted Cloud query domain
  (ADR-0006).
