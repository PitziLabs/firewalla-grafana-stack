# Terraform — Grafana Cloud

Manages everything in the `lentago` Grafana Cloud stack as code: dashboards, folders,
data sources, contact points, notification policies, alert rules, and service accounts.

Dashboard JSON files live in [`../dashboards/`](../dashboards/) and are the source of truth.
Terraform rewrites the original self-hosted datasource UIDs (`loki`, `prometheus`) to the
Grafana Cloud UIDs (`grafanacloud-logs`, `grafanacloud-prom`) at apply time, so the JSON
files stay portable. Note these are the datasource **UIDs** (`grafanacloud-<service>`), not
their stack-prefixed **names** (`grafanacloud-lentago-{logs,prom}`) — panels reference
datasources by UID, so rewriting to the name produces a dangling ref that silently falls
back to the default datasource. The exact mapping lives in [`locals.tf`](locals.tf); verify
against a live stack with the `curl … /api/datasources | jq '.[]|{uid,name}'` snippet there.
Terraform reads them via `file()` and pushes them to Grafana Cloud — never the other way
around. Drift introduced via the Grafana UI gets overwritten on the next `apply`.

## State

Remote state in **S3** ([`backend.tf`](backend.tf)): solidago's state bucket
`solidago-tfstate-365184644049`, key `homelab-observability/terraform.tfstate`, region
`us-east-1`, with DynamoDB lock table `solidago-tfstate-lock`. The bucket is versioned +
encrypted, so the old "back up the local `tfstate` to the NAS" step is gone — S3 is the
single authoritative store shared by local runs and CI.

Local `terraform` uses your own AWS creds (the `default` profile / `cpitzi-iac` user); CI
assumes the `homelab-observability-github-actions-terraform` OIDC role (the role and state key keep the pre-rename `homelab-observability` prefix — the repo became `drosera` on 2026-07-04), scoped to **only**
this state key + the lock table — it cannot touch solidago's own state. (History: state was
laptop-local until 2026-06-19, migrated into S3 to enable apply-on-merge — see CI below.)

## Prerequisites

- Terraform `>= 1.5` (for `import` blocks)
- direnv loading `../.envrc` so `GRAFANA_URL` and `GRAFANA_AUTH` are in your shell
- Service account token in `GRAFANA_AUTH` with **Admin** role on the stack
- AWS creds in your shell (the `default` profile / `cpitzi-iac` user) with access to the S3
  state bucket + lock table — `terraform init`/`plan`/`apply` read & write remote state

## Day-to-day

```bash
cd terraform
terraform init           # one time, or after provider/backend changes
terraform plan           # show drift / pending changes
terraform apply          # apply locally — or just merge to main (see CI below)
```

## CI / apply-on-merge

The [`terraform` workflow](../.github/workflows/terraform.yml) runs on every PR and push
touching `terraform/**` or `dashboards/**`:

- **PR** → `validate` (fmt + validate) and `plan` (posts the diff as a PR comment).
- **push to `main`** → `validate` then **`apply -auto-approve`** — merging a dashboard
  change deploys it automatically; no manual `terraform apply` needed.

CI authenticates to Grafana via the `GRAFANA_URL` / `GRAFANA_AUTH` repo secrets, and to AWS
(for S3 state) via GitHub **OIDC**, assuming
`arn:aws:iam::365184644049:role/homelab-observability-github-actions-terraform` (least
privilege: this state key + the lock table only). The `apply` job uses a `terraform-apply`
concurrency group so two quick merges serialize instead of racing.

The site-probe alerting in [`alerts.tf`](alerts.tf) adds one more required input:
`TF_VAR_alert_email` — the recipient address for the site-probe alert contact point. It is a
**repo secret** (not committed: drosera is a public repo) exposed to the `plan` and `apply`
jobs as an env var, exactly like the Grafana secrets. Two operational prerequisites: (1) add the
`TF_VAR_alert_email` repo secret, and (2) the `GRAFANA_AUTH` service-account token must carry
alert-rule write scope — a token scoped for dashboards only will fail the apply when it
reaches the `grafana_rule_group` / `grafana_contact_point` resources.

The site traffic panels in [`datasources.tf`](datasources.tf) and
[`plugins.tf`](plugins.tf) add two more, following the same repo-secret pattern:

| Secret | Feeds | What it must be |
|---|---|---|
| `TF_VAR_AXIOM_API_TOKEN` | `TF_VAR_axiom_api_token` | An Axiom API token with **query** scope on the `cjp-solidago-alb` dataset. Backs `grafana_data_source.solidago_axiom`. |
| `TF_VAR_GRAFANA_CLOUD_ACCESS_POLICY_TOKEN` | `TF_VAR_grafana_cloud_access_policy_token` | A Grafana **Cloud access policy** token with `stack-plugins:read`, `stack-plugins:write`, `stack-plugins:delete`. Backs `grafana_cloud_plugin_installation.axiom`. |

**The Cloud token is not the same thing as `GRAFANA_AUTH`, and one cannot substitute for the
other.** `GRAFANA_AUTH` is a *stack* service-account token: it manages dashboards, folders,
datasources, and alert rules through the stack API. Installing a plugin is a *Grafana Cloud
Portal* operation on a different API with its own auth, which is why `plugins.tf` declares an
aliased `provider "grafana"` (`alias = "cloud"`) rather than reusing the default provider.
Mint the Cloud token in the Grafana Cloud Portal under Access Policies, not in the stack's
service-account UI.

### Why these variables carry a `validation` block

Every secret-backed variable here declares `validation { length(trimspace(...)) > 0 }`, and
that is load-bearing rather than decorative.

**"No default" does not catch an unset secret in CI.** GitHub Actions renders a reference to a
missing repo secret as an **empty string**, not an error — so `TF_VAR_axiom_api_token=""`
reaches Terraform as a perfectly valid value for a variable that has no default. The plan
succeeds and the apply ships an empty credential. This was observed, not theorised: PR #173's
plan passed cleanly at 01:10Z on 2026-07-25 with `Plan: 2 to add, 4 to change`, thirteen
minutes before either new secret existed.

The `validation` block is what actually fails the run, at plan time, with a message naming the
secret. Add one to any future secret-backed variable in this repo.

This is the same failure shape as lentago/solidago#143, where an unreplaced `PLACEHOLDER`
value in Secrets Manager left the ECS log pipeline dead for 16 days: a credential that is
present, well-formed to every system that touches it, and wrong. Prefer guards that assert a
secret is *usable* over ones that merely assert it is *set*.

## Adopting a new resource that already exists in Cloud

1. Add an `import` block in `imports.tf`:

   ```hcl
   import {
     to = grafana_dashboard.my_new_dashboard
     id = "my-dashboard-uid"
   }
   ```

2. Add the matching `resource` definition in the appropriate `.tf` file.
3. Run `terraform plan` — it should show "1 to import, 0 to add" with no diff.
4. Run `terraform apply`.
5. (Optional) Remove the `import` block once the resource is in state.

## Creating a new dashboard from scratch

1. Drop a JSON file in `../dashboards/`.
2. Add an entry to the matching per-folder map (`lab_dashboards`, `claytonia_dashboards`, `solidago_dashboards`, or `sites_dashboards`) in [`locals.tf`](locals.tf) (the `grafana_dashboard` resources use `for_each` over those maps in [`dashboards.tf`](dashboards.tf)).
3. Add a matching `import` block in [`imports.tf`](imports.tf) if the dashboard was already created in the UI (otherwise Terraform creates it on first apply).
4. `terraform apply`.
