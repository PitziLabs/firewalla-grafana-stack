# terraform/datasources.tf
#
# Datasources we manage ourselves. The stack's built-in datasources
# (grafanacloud-prom / grafanacloud-logs / grafanacloud-infinity) are
# auto-provisioned by Grafana Cloud and deliberately NOT managed here.
#
# Solidago CloudWatch: query-on-demand against the AWS account, via the
# cross-account role provisioned in lentago/solidago (modules/grafana-cloud).
# Auth is "Grafana Assume Role" — Grafana Cloud's own AWS account assumes our
# role, presenting this stack's External ID; no credentials are stored on
# either side. Because IAM role ARNs are deterministic, solidago's nightly
# teardown/standup DR drill recreates the role at the same ARN and this
# datasource never needs re-pointing.

resource "grafana_data_source" "solidago_cloudwatch" {
  type = "cloudwatch"
  name = "Solidago CloudWatch"
  uid  = "solidago-cloudwatch"

  json_data_encoded = jsonencode({
    authType      = "grafana_assume_role"
    assumeRoleArn = "arn:aws:iam::365184644049:role/solidago-dev-grafana-cloudwatch"
    defaultRegion = "us-east-1"
  })
}

# Solidago Axiom: query-on-demand against the ALB access logs that lentago/betula
# ships into the `cjp-solidago-alb` Axiom dataset (betula#87). This is the render
# side of the capture-once boundary — drosera queries Axiom directly; nothing is
# teed into Loki/Mimir. The signed `axiomhq-axiom-datasource` plugin this needs is
# installed by grafana_cloud_plugin_installation.axiom in plugins.tf (pinned to
# 0.7.0), so the stack requirement is codified rather than a manual prerequisite.
#
# The API token is NEVER committed (drosera is a public repo). It is declared as a
# sensitive variable with no default and passed by CI as TF_VAR_axiom_api_token —
# the exact pattern alerts.tf uses for TF_VAR_alert_email. A missing value fails
# the plan loudly rather than shipping an empty credential.
variable "axiom_api_token" {
  type        = string
  sensitive   = true
  description = "Axiom API token for the ALB-logs datasource. Set via TF_VAR_axiom_api_token; never committed (public repo)."

  validation {
    condition     = length(trimspace(var.axiom_api_token)) > 0
    error_message = "The TF_VAR_axiom_api_token secret resolved to an empty string. GitHub Actions renders a MISSING repo secret as empty rather than failing, so 'no default' alone does not catch an unset secret — this check does."
  }
}

resource "grafana_data_source" "solidago_axiom" {
  type = "axiomhq-axiom-datasource"
  name = "Solidago Axiom"
  uid  = "solidago-axiom"

  # accessToken is the plugin's secureJsonData key; it is stored server-side by
  # Grafana and never read back into state as plaintext.
  secure_json_data_encoded = jsonencode({
    accessToken = var.axiom_api_token
  })

  # Explicit: a datasource of this type cannot be created until the plugin that
  # provides it exists on the stack. Nothing in the arguments above references
  # the installation, so Terraform has no implicit edge to infer — without this
  # the two can be ordered arbitrarily and a first apply fails intermittently.
  depends_on = [grafana_cloud_plugin_installation.axiom]
}
