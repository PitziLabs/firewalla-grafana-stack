# One flat folder holds every drosera-owned dashboard. The per-product folder
# taxonomy (Claytonia / Solidago / Sites / Lentago Lab) was collapsed on
# 2026-07-24: with twelve dashboards the folder tree cost a click on every
# navigation and bought nothing a title prefix can't express. Grouping now lives
# in the dashboard title (`<Group> — <What>`), which sorts the flat list into the
# same clusters the folders used to draw. See CLAUDE.md § Key conventions.
#
# The uid is the wizard-imported one from the original Firewalla folder: a folder
# uid change is a destroy/create, and destroying a folder takes its dashboards
# with it. Retitling in place is free, so the opaque uid stays.
resource "grafana_folder" "lentago" {
  title = "Lentago"
  uid   = "afh7m8li40zk0d"
}

# 2026-07-18 product-line reorg (renames in state, no destroy/create):
# grafana_folder.firewalla         -> grafana_folder.lab
# grafana_dashboard.firewalla      -> grafana_dashboard.lab
# ...and the runner-fleet dashboard out of the lab map into claytonia.
moved {
  from = grafana_folder.firewalla
  to   = grafana_folder.lab
}

moved {
  from = grafana_dashboard.firewalla
  to   = grafana_dashboard.lab
}

moved {
  from = grafana_dashboard.lab["claude_runner_fleet"]
  to   = grafana_dashboard.claytonia["runner_fleet"]
}

# 2026-07-24 flattening. The folder resource is renamed rather than replaced so
# the uid — and therefore every dashboard inside it — survives untouched. The
# Claytonia / Solidago / Sites folder resources are simply deleted: their
# dashboards move to this folder in the same apply, and Terraform orders the
# folder deletes after the moves because each dashboard now depends on
# grafana_folder.lentago instead.
moved {
  from = grafana_folder.lab
  to   = grafana_folder.lentago
}
