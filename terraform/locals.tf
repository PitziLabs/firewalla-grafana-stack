locals {
  dashboards_dir = "${path.module}/../dashboards"

  # Dashboard JSON in the repo references the original self-hosted datasource
  # UIDs ("loki" and "prometheus"). On Grafana Cloud the lentago stack
  # auto-provisions datasources whose *UID* is "grafanacloud-<service>"
  # (logs / prom / infinity). The stack-name prefix ("grafanacloud-lentago-*")
  # appears in the datasource *name*, NOT its UID — panels reference datasources
  # by UID, so we must rewrite to the UID, not the name. We rewrite at apply time
  # so the JSON files stay portable.
  #
  # To verify the UIDs on a live stack (note: read .uid, not .name):
  #   curl -s -H "Authorization: Bearer $GRAFANA_AUTH" $GRAFANA_URL/api/datasources \
  #     | jq '.[] | {uid, name}'
  #
  # History: loki/prometheus were previously rewritten to the *name*
  # ("grafanacloud-lentago-{logs,prom}"), which are non-existent UIDs. Prom
  # panels still rendered because the Prometheus datasource is the stack default,
  # so a dangling UID silently fell back to it; all-Loki dashboards (e.g.
  # claude-runner-fleet) showed "No data" because the fallback default is
  # Prometheus, which can't run LogQL. infinity was already correct.
  datasource_uid_rewrites = {
    "loki"       = "grafanacloud-logs"
    "prometheus" = "grafanacloud-prom"
    "infinity"   = "grafanacloud-infinity"
  }

  # Lentago Lab (homelab-source) dashboards. Uids keep the legacy firewalla-
  # prefix: uids are load-bearing (cross-dashboard /d/ links, the office-display
  # public share, the import blocks) and changing one is a destroy/create.
  #
  # These four maps are *groups*, not folders — since the 2026-07-24 flattening
  # every dashboard lands in the one `Lentago` folder, and the grouping is
  # carried by the `<Group> — <What>` dashboard title instead. The maps stay
  # separate because they differ in JSON pre-processing (the solidago set skips
  # the datasource-uid rewrite).
  lab_dashboards = {
    network_overview = {
      uid  = "firewalla-network-overview"
      file = "network-overview.json"
    }
    dns_security = {
      uid  = "firewalla-dns-security"
      file = "dns-security.json"
    }
    traffic_devices = {
      uid  = "firewalla-traffic-devices"
      file = "traffic-devices.json"
    }
    infra_health = {
      uid  = "firewalla-infra-health"
      file = "infra-health.json"
    }
    office_display = {
      uid  = "firewalla-office-display"
      file = "office-display.json"
    }
    neptune_nas = {
      uid  = "firewalla-neptune-nas"
      file = "neptune-nas.json"
    }
  }

  # Read each dashboard JSON file and rewrite datasource UIDs in one pass.
  # The regex tolerates either `"uid": "loki"` or `"uid":"loki"` (and similar
  # for prometheus) so we don't depend on the formatter's whitespace.
  lab_dashboard_json = {
    for k, d in local.lab_dashboards :
    k => replace(
      replace(
        replace(
          file("${local.dashboards_dir}/${d.file}"),
          "/\"uid\":\\s*\"loki\"/",
          "\"uid\": \"${local.datasource_uid_rewrites["loki"]}\""
        ),
        "/\"uid\":\\s*\"prometheus\"/",
        "\"uid\": \"${local.datasource_uid_rewrites["prometheus"]}\""
      ),
      "/\"uid\":\\s*\"infinity\"/",
      "\"uid\": \"${local.datasource_uid_rewrites["infinity"]}\""
    )
  }
}

# Claytonia (agent fleet) dashboards. Same datasource-UID rewrite as the lab
# set — the runner-fleet dashboard is all-Loki (plus Infinity), so it carries
# the legacy self-hosted "loki" placeholder uid. The dashboard uid keeps the
# legacy claude-runner-fleet name so existing links survive the rename.
locals {
  claytonia_dashboards = {
    runner_fleet = {
      uid  = "claude-runner-fleet"
      file = "claytonia-runner-fleet.json"
    }
  }

  claytonia_dashboard_json = {
    for k, d in local.claytonia_dashboards :
    k => replace(
      replace(
        replace(
          file("${local.dashboards_dir}/${d.file}"),
          "/\"uid\":\\s*\"loki\"/",
          "\"uid\": \"${local.datasource_uid_rewrites["loki"]}\""
        ),
        "/\"uid\":\\s*\"prometheus\"/",
        "\"uid\": \"${local.datasource_uid_rewrites["prometheus"]}\""
      ),
      "/\"uid\":\\s*\"infinity\"/",
      "\"uid\": \"${local.datasource_uid_rewrites["infinity"]}\""
    )
  }
}

# Solidago (AWS) dashboards — separate map from the lab set, and
# deliberately NOT routed through the datasource-UID-rewrite machinery above:
# Solidago dashboard JSON references "solidago-cloudwatch" directly, a uid WE
# choose in datasources.tf — unlike the lab dashboards, which predate
# the stack and carry legacy self-hosted uids that must be rewritten at
# apply time.
locals {
  solidago_dashboards = {
    platform_health = {
      uid  = "solidago-platform-health"
      file = "solidago-platform-health.json"
    }
  }

  solidago_dashboard_json = {
    for k, d in local.solidago_dashboards :
    k => file("${local.dashboards_dir}/${d.file}")
  }
}

# Site dashboards — one per public site, uid/file named after the site repo
# (site-<domain-with-dashes>). Unlike the solidago set, these ARE routed
# through the datasource-UID rewrite: site dashboards mix Mimir probe panels
# (the "prometheus" placeholder) with CloudWatch panels ("solidago-cloudwatch",
# a real uid the rewrite regexes never match, so it passes through untouched).
locals {
  sites_dashboards = {
    pondviewlane_com = {
      uid  = "site-pondviewlane-com"
      file = "site-pondviewlane-com.json"
    }
    icecreamtofightwith_com = {
      uid  = "site-icecreamtofightwith-com"
      file = "site-icecreamtofightwith-com.json"
    }
    lentago_dev = {
      uid  = "site-lentago-dev"
      file = "site-lentago-dev.json"
    }
    essexcrossingatmontserrat_com = {
      uid  = "site-essexcrossingatmontserrat-com"
      file = "site-essexcrossingatmontserrat-com.json"
    }
  }

  sites_dashboard_json = {
    for k, d in local.sites_dashboards :
    k => replace(
      replace(
        replace(
          file("${local.dashboards_dir}/${d.file}"),
          "/\"uid\":\\s*\"loki\"/",
          "\"uid\": \"${local.datasource_uid_rewrites["loki"]}\""
        ),
        "/\"uid\":\\s*\"prometheus\"/",
        "\"uid\": \"${local.datasource_uid_rewrites["prometheus"]}\""
      ),
      "/\"uid\":\\s*\"infinity\"/",
      "\"uid\": \"${local.datasource_uid_rewrites["infinity"]}\""
    )
  }
}
