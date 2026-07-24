# ADR-0001: Grafana-native alerting for site probes

**Status:** Accepted (2026-07-24)

## Context

drosera runs external blackbox probes against the public Lentago sites from
the lab Alloy (`prometheus.exporter.blackbox`) and remote-writes the results to
Grafana Cloud Mimir. Two probe-derived signals matter for site health:

- `probe_success` — the site is reachable from outside (0 = down, 1 = up).
- `probe_ssl_earliest_cert_expiry` — the TLS cert's expiry timestamp.

Neither metric exists in CloudWatch. They are produced by the lab, not by AWS,
and are never emitted to the AWS account. Solidago's ADR-0001 ("Grafana is
visualization, not alerting") deliberately keeps *platform* alerting
AWS-native — ALB/ECS/RDS metrics → CloudWatch alarms → SNS. That posture is
correct for platform metrics but **cannot** cover site-down-from-outside or
certificate expiry, because CloudWatch cannot see metrics that only exist in
Mimir. AWS-native alerting is therefore not one of two workable options here;
it is a non-option for these two signals.

A live audit on 2026-07-24 (#156) confirmed the starting point: zero Grafana
alert rules, zero contact points, `terraform/.bootstrap/{alert_rules,contact_points}.json`
both `[]`. There is no notification path from any failure in this fleet to a
human, on any surface. pondviewlane.com went public on 2026-07-17 — a site of
record for residents, buyers, attorneys, and title searchers — so a silent
outage is no longer acceptable.

## Decision

**Probe-derived signals get Grafana-native alerting.** drosera grows a
terraform-managed Grafana alerting surface (`terraform/alerts.tf`): an email
contact point and one `grafana_rule_group` in the **Sites** folder, driven by a
local list of site domains (`local.probe_alert_sites`) so adding a future site
is a one-line change — mirroring the per-site client model the dashboards
already use. Two rules per domain:

- **Site down** — `probe_success == 0`, `for = 5m`.
- **Certificate expiry** — `probe_ssl_earliest_cert_expiry - time() < 21d`.

The probe `job` label is exactly `integrations/blackbox/<domain>`.

**Solidago ADR-0001's boundary is untouched.** Platform metrics (ALB, ECS, RDS)
stay AWS-native — CloudWatch alarms → SNS remain their sole alerting plane. No
CloudWatch-sourced alert rules are added by this decision; drosera's Grafana
alerting is scoped strictly to Mimir-only probe metrics. The two ADRs partition
cleanly by metric origin: AWS metrics alert in AWS, lab-produced probe metrics
alert in Grafana.

### NoData is not suppressed (the one real judgment call)

The probes run from a **single LAN vantage point**, so a lab or WAN outage is
indistinguishable from a site outage: if the lab is down, the probe is down.
`no_data_state = "NoData"` and `exec_err_state = "Error"` — NoData is **not**
suppressed. Suppressing it (`no_data_state = "OK"`) would mean a genuine site
outage occurring *during* a lab outage produces no alert at all. The failure
mode of this entire effort would then be silence — exactly what it exists to
eliminate. Accepting some false-positive noise (a lab hiccup pages us about a
site that is actually fine) is the correct trade. The blind spot is stated
plainly rather than papered over: LAN-vantage alerting cannot distinguish
"site down" from "we can't see the site." If outside-in independence later
matters, Grafana Synthetic Monitoring / k6 is the escalation path — a separate
decision, not this one.

### Routing is per-rule, not the root policy

Routing uses the `notification_settings` block on each rule (receiver = the
email contact point) rather than `grafana_notification_policy`. The root
notification policy is a single stack-wide resource; adopting it would put the
entire stack's routing under this repo's control — a far larger blast radius
than this issue asks for. Per-rule settings scope routing to these rules only.
`repeat_interval = "4h"` throttles re-notification so an ongoing outage does not
mail every 60s evaluation cycle.

## Consequences

- drosera now owns a live Grafana alerting surface. It is created the moment
  this lands, since terraform applies on every merge to `main`.
- The recipient address is **not** committed (public repo). It is supplied as
  `TF_VAR_alert_email`; the `variable "alert_email"` has no default, so a
  missing value fails the plan loudly.
- Alerting depends on the lab Alloy remote-writing to Mimir and on the Grafana
  Cloud free tier. Unlike the platform plane (whose alerting survives a lab or
  Grafana outage per solidago ADR-0001), this plane does not — accepted above
  as the price of covering metrics that live nowhere else.
- Any future expansion (alerting on CloudWatch metrics from Grafana, adopting
  the root notification policy, or adding outside-in synthetic checks) requires
  revisiting this ADR and, where it touches platform metrics, solidago
  ADR-0001.
