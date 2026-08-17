# ADR-0008: Site availability SLOs and multi-window burn-rate alerts

**Status:** Accepted (2026-08-17)

## Context

drosera already alerts on site health from the lab Alloy's blackbox probes
(ADR-0001): `probe_success == 0` pages, `probe_ssl_earliest_cert_expiry` warns
on impending TLS expiry. Both are **symptom** alerts — they fire on the raw
condition, right now. A symptom alert has no notion of _how much_ downtime is
acceptable: a 30-second lab-WAN blip and a two-hour real outage trip the same
"Site down" rule, and the only knob to damp the blip is a fixed `for` duration,
which trades detection latency for noise uniformly regardless of severity.

What was missing is an **objective**: a stated availability target, an error
budget derived from it, and alerts that fire on the _rate at which the budget is
being consumed_ rather than on the instantaneous symptom. The 2026-08
architecture review flagged this as item R14. Issue #195 scopes it to the three
public sites — lentago.dev, icecreamtofightwith.com, pondviewlane.com.

## Decision

### The SLO: 99.9% availability over a rolling 30-day window

Availability is defined as the fraction of successful outside-in blackbox probes
over the window: `avg_over_time(probe_success[30d])`. The target is **99.9%**,
which allows **43.2 minutes** of downtime per 30-day window.

**Why 99.9% and not 99.99%.** This is a free-tier, homelab-fronted lab. The
probe path crosses a residential WAN, a Proxmox LXC, and Grafana Cloud's free
tier — none of which carries a four-nines guarantee, and the lab is not staffed
for four-nines response. 99.99% is 52 minutes per _year_; a single 5-minute
home-internet outage blows a year of that budget. Publishing 99.99% would be
theatre — a number the infrastructure cannot honour, which trains everyone to
ignore the resulting alert storm. 99.9% is honest: achievable on this stack,
yet tight enough that a real regression surfaces as budget burn rather than
disappearing into noise. The measurement window is 30 days because that is the
window the Google SRE Workbook's canonical burn-rate table is derived for, so
the multipliers below (14.4, 3) are directly comparable to the published
reference instead of re-derived for a bespoke window.

**Three public sites only.** essexcrossingatmontserrat.com has a probe but is
deliberately excluded: it shares pondviewlane.com's ECS service (different
`domain_name`, one service), so its availability is not an independent
objective. The claytonia queue SLO is a separate objective tracked in #200.

### Multi-window, multi-burn-rate alert pairs

Per the SRE Workbook's "Alerting on SLOs" chapter, each site gets a **pair** of
alerts, each combining a long and a short window (both must exceed the threshold
to fire — the short window confirms the burn is _still happening_, which gives
the alert a fast reset once the incident clears):

| Tier | Burn rate | Long ∧ short window | Budget burned | Action | `for` | Severity |
|------|-----------|---------------------|---------------|--------|-------|----------|
| Fast | **14.4×** | 1h ∧ 5m | 2% of the 30d budget in 1h | **Page** | 2m | critical |
| Slow | **3×** | 24h ∧ 2h | 10% of the budget in 24h | **Ticket** | 15m | warning |

Burn rate = `(1 - avg_over_time(probe_success[w])) / 0.001` — the failed-probe
fraction over the window divided by the error-budget fraction (1 − 0.999). A
burn rate of 1 exhausts the whole month's budget in exactly 30 days; 14.4
exhausts it in ~50 hours. The fast tier pages because at that rate the budget is
gone within two days; the slow tier tickets because the budget will exhaust this
month if left unattended but nothing is on fire.

This is deliberately **two tiers, not the Workbook's full four**. The point of
SLO alerting is _fewer, better_ alerts — a page that means "this threatens the
budget" and a ticket that means "investigate during business hours" — not more
rules. Windows are capped at 24h (the slow tier uses the Workbook's alternative
3×/24h ticket tier rather than its 1×/3d tier) because a 3-day `avg_over_time`
is a heavy Mimir range query for a marginal gain in sensitivity.

### Consistency with the existing alerting surface

- **Same contact point, per-rule routing.** The six rules route through the
  existing `Site probe email` contact point via each rule's
  `notification_settings`, so the root notification policy tree stays untouched
  (ADR-0001's boundary). The page tier re-notifies hourly, the ticket tier every
  12h.
- **`no_data_state = "NoData"`**, identical to the symptom-probe group and for
  the same reason: a single-vantage probe cannot distinguish a real outage from
  a lab/WAN outage, so suppressing NoData (→ "OK") would silence a genuine site
  outage that coincides with a lab outage. The failure mode stays noise, never
  silence. (Contrast the ingest-absence group, where NoData _is_ the failure and
  is set to "Alerting" — the stance is re-derived per signal, never copied.)
- **The symptom rules stay.** A hard-down still pages immediately via ADR-0001's
  "Site down" rule; this group adds budget-aware routing _on top_, it does not
  replace instantaneous-down detection.

### No new series

Burn rate is computed inline with `avg_over_time()` at evaluation time. There
are **no recording rules**, so this adds **zero active series** to Mimir (the
stack runs ~9k of the 15k free-tier cap — ADR-0005). Grafana-managed alert rules
evaluate in Grafana's engine and are not remote-written back to Mimir either.
The dashboard panels compute the same expressions on the fly.

## Consequences

- drosera now states an availability objective it can be held to. The SLO board
  (`dashboards/sites-slo-error-budget.json`, uid `sites-slo-error-budget`) shows
  per-site attainment, budget remaining (percent and minutes), and multi-window
  burn rate — the operator's view of the same math the alerts fire on.
- Six new rules land in `terraform/alerts.tf` (group **Site SLO burn rate**),
  applied on merge like every other rule group.
- The SLO inherits ADR-0001's LAN-vantage blind spot: burn-rate attainment
  reflects reachability _from the lab_, not global reachability. If outside-in
  independence later matters, Grafana Synthetic Monitoring / k6 is the escalation
  path — a separate decision.
- Changing the target, the window, or the burn multipliers is a change to this
  ADR. Adding a fourth site to the SLO set is a one-line change to
  `local.slo_sites`; whether a new site _should_ carry an independent objective
  (cf. the essex/pondview shared-service exclusion) is a judgment to record here.
