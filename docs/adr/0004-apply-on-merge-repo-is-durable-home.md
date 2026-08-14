# ADR-0004: Apply-on-merge; the repo is the only durable home for dashboard state

**Status:** Accepted (2026-06-19; reconstructed 2026-08-13)

## Context

Once dashboards live as checked-in JSON managed by Terraform (ADR-0002), there
are two ways to get an edit into the live Grafana stack: change the repo and let
CI apply it, or edit the live dashboard directly (UI, HTTP API, or the Grafana
MCP server) and hope the change persists. These two paths are not co-equal: one
of them is durable and one of them is not.

## Decision

**Terraform applies `dashboards/*.json` on every merge to `main`** (PR #86,
"ci(terraform): auto-apply dashboards on merge to main (S3-backed state)",
merged 2026-06-19). The apply runs via GitHub OIDC against S3-backed state; no
Grafana container restart is involved.

The direct consequence, made doctrine after an incident, is that **the repo is
the only durable home for dashboard state.** A live-only edit survives exactly
until the next merge to `main` — *any* merge — because that merge's apply
re-pushes repo state over whatever is live. UI editing is tolerated only as an
*input method*: make the change live if that is the fastest way to get it right,
but export it back into the repo JSON in the same session or it will be
destroyed.

This was not theoretical. On 2026-07-03 an infra-health fleet-scoreboard revamp
was pushed live via the API but never committed; five unrelated bug-fix merges
each ran the apply and reverted it. PR #119 restored the lost work from Grafana's
version history, and PR #120 added the anti-drift rule to CLAUDE.md so the
lesson is enforced going forward. The recovery path is on record: Grafana keeps
dashboard version history (`GET /api/dashboards/uid/<uid>/versions`), so a lost
live version can be pulled back, stripped of `id`/`version`, and re-normalized to
the repo's datasource placeholders.

A sharp corollary: the Grafana MCP server authenticates as the **same
`terraform-iac` service account** as CI, so Grafana's version history cannot
distinguish a live MCP edit from a Terraform apply. `createdBy` is useless for
spotting drift — the only reliable signal is comparing live panels against the
repo JSON.

## Alternatives

- **Manual/out-of-band `terraform apply`.** *Recorded, available but not the
  default.* Still supported against the same S3 backend for out-of-band work,
  but relying on it as the primary path invites the exact drift the apply-on-
  merge model closes: state that is correct in the repo but never pushed, or
  pushed but never committed.
- **Treat UI editing as a first-class authoring surface (live is truth).**
  *Recorded, rejected.* Incompatible with apply-on-merge — the next merge
  reverts it — and it reopens the repo-vs-UI drift that motivated the Cloud
  migration (ADR-0002). UI editing is kept only as an input method that must be
  exported back.
- **Grafana-native git-sync / provisioning (as-code without Terraform apply).**
  *Retrospective — not considered at the time.* Lateral. Grafana's own
  git-backed provisioning would also make the repo the source of truth and
  overwrite live edits, so it lands in the same place on the property that
  matters. It would trade the Terraform+OIDC+S3 pipeline (already shared with
  the rest of the stack's IaC) for a Grafana-specific sync mechanism — a
  sideways move that fragments the IaC story rather than improving it, given
  Terraform already manages folders, datasources, and alert rules here.

## Consequences

- Merging to `main` is a live mutation of a SaaS surface. There is no staging
  Grafana; a bad dashboard JSON reaches production on merge.
- Live-ahead-of-repo state is a fire, not a curiosity: if live panels don't
  match the repo, someone's un-codified work is one merge from deletion and must
  be recovered into a PR *before* anything else merges.
- Drift cannot be detected via `createdBy` (shared service account). The
  standing defense is the CLAUDE.md anti-drift rule and version-history recovery,
  not tooling that distinguishes edit sources.
- Alerting IaC (`terraform/alerts.tf`) rides the same apply-on-merge path, so
  this decision governs the alerting surface too, not just dashboards.
