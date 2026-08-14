# ADR-0002: Grafana Cloud + Alloy + Terraform over the self-hosted stack

**Status:** Accepted (2026-05-12; reconstructed 2026-08-13)

## Context

The original incarnation of this repo ran Loki, Prometheus, Grafana, and
blackbox-exporter together on a single Proxmox LXC via `docker compose`, with
file-based provisioning. It worked, but the README's "Why this layout" section
records three standing pains:

1. **Storage on the LXC** — the Prometheus TSDB plus Loki chunks meant disk
   pressure and one more thing to keep an eye on.
2. **Repo-vs-UI drift** — anything edited in the Grafana UI was lost on the next
   provisioner reload, and there was no discipline forcing edits back into the
   repo.
3. **No upgrade story** — each `docker compose pull` of the Grafana image was a
   gamble against a self-managed, stateful box.

This is a learning lab on a hobbyist budget, so any replacement had to fit
inside a free tier rather than add recurring cost.

## Decision

Migrate the whole stack to **Grafana Cloud free tier + Grafana Alloy +
Terraform** (PR #28, merged 2026-05-12). Storage, Grafana upgrades, and query
execution move to Cloud (Mimir for metrics, Loki for logs); a single Alloy
`docker compose` service on the LXC handles collection (blackbox probes, the
Home Assistant scrape, a Loki receiver, and `remote_write`/`loki.write` to
Cloud); Terraform plus checked-in dashboard JSON makes the repo the source of
truth, with UI edits overwritten on the next apply.

The merge of #28 was not the deployment: the change sat undeployed until gap
issue #30 (2026-05-23, "PR #28 never deployed — LXC 105 still runs the legacy
stack") flagged that the box was still running the old compose stack. The
decision and its rollout were separated in time, and #30 is the record of the
gap being closed.

The legacy self-hosted Loki + Prometheus + Grafana compose file is now
**removed**, and CLAUDE.md bans reintroducing it without an issue — the ban
exists so the three pains above cannot quietly creep back.

## Alternatives

- **Keep the self-hosted single-LXC stack (status quo).** *Recorded, rejected.*
  It carried all three pains above and offered no free-tier storage or managed
  upgrades. Worse on every axis that motivated the change.
- **Grafana Cloud + Alloy + Terraform.** *Recorded, chosen.* Free-tier storage,
  managed Grafana upgrades, and a repo-as-source-of-truth model via Terraform.
  The cost is a hard active-series cap (see ADR-0005) and dependence on a SaaS
  free tier's terms — accepted deliberately.
- **A hosted SaaS observability product (Datadog, New Relic, or similar).**
  *Retrospective — not considered at the time.* Worse for this lab. These price
  by host/ingest and have no comparable free tier for continuous home-lab
  telemetry; adopting one would have replaced "manage a box" with "pay a
  monthly bill," which contradicts the free-tier-as-constraint stance that
  shapes the rest of this repo (ADR-0005). It would have removed the
  series-budget engineering entirely, but at a recurring cost the project was
  explicitly built to avoid — so, lateral on operability, worse on the
  constraint that actually mattered.

## Consequences

- Storage, Grafana upgrades, and query execution are Grafana's problem now; the
  LXC runs only Alloy.
- The repo (Terraform + dashboard JSON) becomes the durable home for dashboard
  and alerting state. That is a benefit here and the seed of a hazard —
  apply-on-merge means the repo can silently revert live edits, which is its own
  decision (ADR-0004).
- The project inherits a free-tier active-series cap, making series-budget
  engineering a standing concern (ADR-0005).
- Reintroducing the self-hosted stack is gated behind an issue, so any
  regression toward the old pains is a deliberate, reviewed act.
