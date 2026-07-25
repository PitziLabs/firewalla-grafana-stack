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

# One rule group holding every site-probe rule. A rule group's identity is
# `<folder_uid>:<name>`, so the 2026-07-24 folder flattening replaces this group
# rather than updating it — the rules are recreated identically and any in-flight
# alert state resets once. Expect that on the flattening apply only.
resource "grafana_rule_group" "site_probes" {
  name             = "Site probe alerts"
  folder_uid       = grafana_folder.lentago.uid
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

# ---------------------------------------------------------------------------
# Ingest-absence alerts for the critical Loki streams (issue #150).
#
# WHY this is separate from the probe rules above: the failure class it catches
# is *silent ingest death*, not site downtime. Every silent failure this quarter
# was an ingest failure — a 3-day and a 9-day Loki outage (the 2026-07-10 incident
# report) and a 16-day Axiom outage (solidago#143), all of which stayed green on
# every existing safeguard. Nothing in the stack asked "is data still arriving?"
# These rules do exactly that: for each stream, count the lines over a cadence-
# appropriate window and alert when the count is zero OR the query returns no data.
#
# no_data_state = "Alerting" IS THE CRUX and is DELIBERATELY OPPOSITE to the probe
# rules above (which use "NoData"). For an absence alert, "no data" is not an
# ambiguous vantage-point failure — it is precisely the condition being watched
# for. A stopped stream produces an *empty* Loki result (a range-vector selector
# that matches no lines returns nothing, not a literal 0), so if NoData were
# suppressed or merely surfaced as NoData, these rules would stay silent through
# the very outage they exist to catch. The threshold on C (< 1) is the belt to
# no_data_state's suspenders for the rare case the query does return 0.
#
# SELECTOR CAVEAT: select on `log_source` ALONE. Streams may carry
# cluster="lentago-lab" (Fluent Bit / Alloy external_labels) while pre-2026-07-04
# data carries cluster="homelab"; adding a `cluster` matcher risks a selector that
# matches nothing and therefore never fires — the worst outcome for an absence rule.
locals {
  # Per-stream model, one entry per stream: adding a stream is a one-line change.
  # `window` is the count_over_time lookback (sized to each stream's cadence);
  # `from_seconds` is the rule's relative_time_range and must cover that window.
  #
  # firewalla_acl is the one stream the 2026-07-24 design comment on #150 flags as
  # fragile for pure absence detection: it is event-driven (ACL alarms only emit on
  # a matching blocked/allowed flow), so a legitimately quiet network can produce a
  # real zero. The comment's principle — constant-volume streams (zeek_dns/zeek_conn)
  # alert directly; a heartbeat is the robust mechanism for genuinely quiet streams —
  # is honoured here two ways: (1) firewalla_acl gets a materially wider 2h window so
  # a false zero is implausible on any active network, and (2) device_inventory needs
  # no special handling because its hourly cron IS a heartbeat — a known-cadence
  # emitter whose absence is unambiguous. A synthetic ACL-liveness heartbeat that
  # would let firewalla_acl detect faster is the robust long-term fix and is out of
  # scope for this Loki-only issue (see PR body).
  loki_ingest_streams = [
    {
      key          = "zeek-dns"
      stream       = "zeek_dns"
      name         = "Ingest absence — zeek_dns"
      window       = "30m"
      from_seconds = 1800
      summary      = "No zeek_dns log lines ingested in the last 30m. This is a constant, high-volume stream — a zero means the Firewalla Fluent Bit DNS shipper has stopped delivering to Cloud Loki."
    },
    {
      key          = "zeek-conn"
      stream       = "zeek_conn"
      name         = "Ingest absence — zeek_conn"
      window       = "30m"
      from_seconds = 1800
      summary      = "No zeek_conn log lines ingested in the last 30m. This is a constant, high-volume stream — a zero means the Firewalla Fluent Bit conn shipper has stopped delivering to Cloud Loki."
    },
    {
      key          = "firewalla-acl"
      stream       = "firewalla_acl"
      name         = "Ingest absence — firewalla_acl"
      window       = "2h"
      from_seconds = 7200
      summary      = "No firewalla_acl log lines ingested in the last 2h. This is a lower-volume, event-driven stream (ACL alarms); the 2h window is sized so a legitimately quiet network is unlikely to produce a false zero. A sustained gap indicates the ACL alarm shipper has stopped."
    },
    {
      key          = "device-inventory"
      stream       = "device_inventory"
      name         = "Ingest absence — device_inventory"
      window       = "3h"
      from_seconds = 10800
      summary      = "No device_inventory entries in the last 3h. This feed is an hourly cron via the central Alloy loki.source.api; a 3h gap means the publisher has missed ~2 runs and LAN name↔IP resolution is going stale."
    },
  ]
}

# One rule group for the four homelab-source feeds (Zeek/ACL from the Firewalla,
# device_inventory from the lab Alloy). This group was already in the folder that
# the 2026-07-24 flattening renamed to "Lentago", so the reference change below is
# uid-identical and the group is updated in place, not replaced.
resource "grafana_rule_group" "loki_ingest_absence" {
  name             = "Loki ingest absence"
  folder_uid       = grafana_folder.lentago.uid
  interval_seconds = 60

  dynamic "rule" {
    for_each = { for r in local.loki_ingest_streams : r.key => r }

    content {
      name = rule.value.name
      # 10m persistence guard so a single transient empty result / Loki hiccup
      # does not page; negligible next to each stream's window.
      for = "10m"

      # See the block comment above: "no data" is the alerting condition here,
      # NOT an ambiguous vantage-point failure. Getting this backwards produces
      # rules that stay silent through the outage they exist to catch.
      condition      = "C"
      no_data_state  = "Alerting"
      exec_err_state = "Error"

      # A: sum(count_over_time({log_source="X"}[window])) against Cloud Loki.
      # The Loki datasource UID is hardcoded exactly as the probe rules hardcode
      # grafanacloud-prom — the datasource_uid_rewrites machinery in locals.tf
      # rewrites dashboard JSON only, never alert rules.
      data {
        ref_id         = "A"
        datasource_uid = "grafanacloud-logs"

        relative_time_range {
          from = rule.value.from_seconds
          to   = 0
        }

        model = jsonencode({
          refId         = "A"
          expr          = "sum(count_over_time({log_source=\"${rule.value.stream}\"}[${rule.value.window}]))"
          queryType     = "instant"
          editorMode    = "code"
          intervalMs    = 1000
          maxDataPoints = 43200
          datasource = {
            type = "loki"
            uid  = "grafanacloud-logs"
          }
        })
      }

      # C: fire when the reduced value of A is < 1 (i.e. exactly 0). The empty-
      # result / stream-gone case never reaches this evaluator — it surfaces as
      # NoData and is handled by no_data_state = "Alerting" above.
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
              params = [1]
            }
            operator = { type = "and" }
            query    = { params = ["A"] }
            reducer  = { type = "last", params = [] }
          }]
        })
      }

      # Reuse the single existing contact point (issue #150 says do not add a
      # second). Per-rule routing only — NOT the root notification policy.
      # repeat_interval throttles re-notification so a deliberate quiet period
      # (e.g. Firewalla maintenance) does not mail every evaluation cycle.
      notification_settings {
        contact_point   = grafana_contact_point.site_alerts_email.name
        repeat_interval = "4h"
      }

      labels = {
        service = "loki-ingest"
        stream  = rule.value.stream
      }

      annotations = {
        summary = rule.value.summary
      }
    }
  }
}
