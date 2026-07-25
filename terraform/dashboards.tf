# Every dashboard lands in the single `lentago` folder (see folders.tf). The
# four maps below are kept as separate resources because they differ in how
# their JSON is pre-processed — the solidago set deliberately skips the
# datasource-uid rewrite (see locals.tf) — not because they map to folders any
# more. Grouping is expressed in the dashboard title.

resource "grafana_dashboard" "lab" {
  for_each = local.lab_dashboards

  folder      = grafana_folder.lentago.uid
  overwrite   = true
  config_json = local.lab_dashboard_json[each.key]
}

resource "grafana_dashboard" "claytonia" {
  for_each = local.claytonia_dashboards

  folder      = grafana_folder.lentago.uid
  overwrite   = true
  config_json = local.claytonia_dashboard_json[each.key]
}

resource "grafana_dashboard" "solidago" {
  for_each = local.solidago_dashboards

  folder      = grafana_folder.lentago.uid
  overwrite   = true
  config_json = local.solidago_dashboard_json[each.key]
}

resource "grafana_dashboard" "sites" {
  for_each = local.sites_dashboards

  folder      = grafana_folder.lentago.uid
  overwrite   = true
  config_json = local.sites_dashboard_json[each.key]
}
