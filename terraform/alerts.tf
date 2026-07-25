# terraform/alerts.tf
#
# Grafana-native alerting for the site probes. See docs/adr/0001-grafana-native-
# alerting-for-site-probes.md for the decision and its boundary.
#
# WHY this lives in Grafana and not AWS: `probe_success` and
# `probe_ssl_earliest_cert_expiry` are produced by the lab Alloy's blackbox
# exporter and remote-written to Mimir. They exist NOWHERE in CloudWatch, so the
# AWS-native alerting posture from solidago ADR-0001 (ALB/ECS/RDS → CloudWatch →
# SNS) physically cannot see them. This file covers ONLY those probe-derived
# signals; it does not add any CloudWatch-sourced rules — that boundary stays
# intact.

# drosera is a PUBLIC repo — the recipient address is never committed. CI passes
# it as TF_VAR_alert_email (see terraform/README.md § CI). No default: a missing
# value fails the plan loudly rather than silently shipping alerts nowhere.
variable "alert_email" {
  type        = string
  sensitive   = true
  description = "Recipient for site-probe alert notifications. Set via TF_VAR_alert_email; never committed (public repo)."

  validation {
    condition     = length(trimspace(var.alert_email)) > 0
    error_message = "The TF_VAR_alert_email secret resolved to an empty string. GitHub Actions renders a MISSING repo secret as empty rather than failing, so 'no default' alone does not catch an unset secret — this check does."
  }
}

# First contact point on the stack (the live audit in #156 found zero). Routing
# is scoped per-rule via notification_settings below, so this does NOT touch the
# root notification policy tree.
resource "grafana_contact_point" "site_alerts_email" {
  name = "Site probe email"

  email {
    addresses = [var.alert_email]
  }
}

locals {
  # Per-site client model, mirroring the dashboards: adding a future site is a
  # one-line change here. Keep in sync with local.sites_dashboards in locals.tf.
  probe_alert_sites = [
    "pondviewlane.com",
    "essexcrossingatmontserrat.com",
    "lentago.dev",
    "icecreamtofightwith.com",
  ]

  # 21-day cert-expiry threshold (issue #156), expressed in seconds because the
  # query yields seconds-until-expiry (`probe_ssl_earliest_cert_expiry - time()`).
  cert_expiry_threshold_seconds = 21 * 24 * 60 * 60 # 1814400

  # Two rules per site, flattened so a single dynamic "rule" block emits them all.
  # The `job` label is exactly `integrations/blackbox/<domain>` — verified live,
  # do not guess a different shape.
  probe_alert_rules = flatten([
    for domain in local.probe_alert_sites : [
      {
        key       = "${domain}-down"
        domain    = domain
        name      = "Site down — ${domain}"
        expr      = "probe_success{job=\"integrations/blackbox/${domain}\"}"
        threshold = 1 # probe_success is 0 (down) or 1 (up); fire when < 1
        for       = "5m"
        summary   = "External probe for ${domain} has reported down (probe_success == 0) for 5m."
      },
      {
        key       = "${domain}-cert-expiry"
        domain    = domain
        name      = "TLS cert expiring — ${domain}"
        expr      = "probe_ssl_earliest_cert_expiry{job=\"integrations/blackbox/${domain}\"} - time()"
        threshold = local.cert_expiry_threshold_seconds
        for       = "1h" # slow-moving; 1h `for` only suppresses transient scrape gaps
        summary   = "TLS certificate for ${domain} expires in under 21 days."
      },
    ]
  ])
}

# One rule group in the Sites folder holding every site-probe rule.
resource "grafana_rule_group" "site_probes" {
  name             = "Site probe alerts"
  folder_uid       = grafana_folder.sites.uid
  interval_seconds = 60

  dynamic "rule" {
    for_each = { for r in local.probe_alert_rules : r.key => r }

    content {
      name      = rule.value.name
      condition = "C"
      for       = rule.value.for

      # LAN-vantage blind spot: the probes run from a single lab vantage point,
      # so a lab/WAN outage is indistinguishable from a site outage. We deliberately
      # do NOT suppress NoData — suppressing it (no_data_state = "OK") would mean a
      # real site outage during a lab outage produces NO alert at all. The failure
      # mode of this whole effort must be noise, never silence. See the ADR.
      no_data_state  = "NoData"
      exec_err_state = "Error"

      # A: the raw probe value from Mimir (0/1 for probe_success, seconds-remaining
      # for the cert query). Kept unfiltered so "healthy" is a value, not an empty
      # result — filtering to empty in PromQL would masquerade as NoData when the
      # site is fine.
      data {
        ref_id         = "A"
        datasource_uid = "grafanacloud-prom"

        relative_time_range {
          from = 600
          to   = 0
        }

        model = jsonencode({
          refId         = "A"
          instant       = true
          range         = false
          editorMode    = "code"
          expr          = rule.value.expr
          intervalMs    = 1000
          maxDataPoints = 43200
          datasource = {
            type = "prometheus"
            uid  = "grafanacloud-prom"
          }
        })
      }

      # C: threshold on A. `lt threshold` fires site-down (value < 1) and
      # cert-expiry (seconds-remaining < 21d) with the same evaluator shape.
      data {
        ref_id         = "C"
        datasource_uid = "__expr__"

        relative_time_range {
          from = 0
          to   = 0
        }

        model = jsonencode({
          refId = "C"
          type  = "classic_conditions"
          datasource = {
            type = "__expr__"
            uid  = "__expr__"
          }
          conditions = [{
            type = "query"
            evaluator = {
              type   = "lt"
              params = [rule.value.threshold]
            }
            operator = { type = "and" }
            query    = { params = ["A"] }
            reducer  = { type = "last", params = [] }
          }]
        })
      }

      # Per-rule routing — NOT the root notification policy. Keeping routing here
      # scopes it to these rules only; adopting grafana_notification_policy would
      # put the whole stack's routing under this repo (much larger blast radius).
      # repeat_interval throttles re-notification so an ongoing outage doesn't mail
      # every 60s evaluation cycle.
      notification_settings {
        contact_point   = grafana_contact_point.site_alerts_email.name
        repeat_interval = "4h"
      }

      labels = {
        service = "site-probe"
        domain  = rule.value.domain
      }

      annotations = {
        summary = rule.value.summary
      }
    }
  }
}
