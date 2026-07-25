# terraform/plugins.tf
#
# Grafana Cloud plugin installations.
#
# This is the ONLY file in this repo that talks to the Grafana Cloud API rather
# than the stack API, and it needs its own credential to do so. The two are
# separate auth domains: GRAFANA_AUTH is a stack service-account token and can
# manage dashboards, datasources, folders, and alert rules, but it cannot install
# a plugin. Plugin installation is a Cloud-Portal operation gated by an access
# policy token with the stack-plugins:read / :write / :delete scopes.
#
# Why codify this at all: every other surface on this stack is terraform-enforced
# from this repo, and apply-on-merge reverts anything that is not. A hand-installed
# plugin would be live state with no source of truth — the exact failure mode that
# silently reverted a dashboard revamp in #119. If the plugin can be managed here,
# it should be.

variable "grafana_cloud_access_policy_token" {
  type        = string
  sensitive   = true
  description = "Grafana Cloud access policy token with stack-plugins:read/write/delete. Set via TF_VAR_grafana_cloud_access_policy_token; never committed (public repo)."
}

variable "grafana_stack_slug" {
  type        = string
  default     = "lentago"
  description = "Grafana Cloud stack slug (the <slug>.grafana.net subdomain). Not a secret."
}

# Aliased provider: Cloud API auth, distinct from the default stack-scoped provider
# in providers.tf. Only the plugin-installation resource below uses it.
provider "grafana" {
  alias                     = "cloud"
  cloud_access_policy_token = var.grafana_cloud_access_policy_token
}

# The Axiom datasource plugin, required by grafana_data_source.solidago_axiom in
# datasources.tf. Version is pinned deliberately — an unpinned plugin would drift
# under us on every apply, and this is the query path for the site traffic panels.
resource "grafana_cloud_plugin_installation" "axiom" {
  provider = grafana.cloud

  stack_slug = var.grafana_stack_slug
  slug       = "axiomhq-axiom-datasource"
  version    = "0.7.0"
}
