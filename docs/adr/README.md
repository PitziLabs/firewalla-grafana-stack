# Architecture decision records

This directory records the architectural decisions behind drosera as short,
dated decision records (the ADR / MADR style used across the fleet).

**Provenance.** ADR-0001 was written at decision time. ADR-0002 through
ADR-0007 were **reconstructed on 2026-08-13** from this repo's commit history,
issues and PRs, `CLAUDE.md`, the README, incident notes, and fleet session
archives — part of a fleet-wide ADR reconstruction. Their **Status** dates are
the *original* decision dates (with `reconstructed 2026-08-13` noted alongside),
not the day the record was authored. Every issue/PR/file/date anchor was
verified against the repo before being asserted; each **Alternatives** section
distinguishes options weighed at the time from ones marked *"retrospective —
not considered at the time,"* which were assessed after the fact and are never
presented as historical deliberation.

## Index

| ADR | Title | Decided |
|-----|-------|---------|
| [0001](0001-grafana-native-alerting-for-site-probes.md) | Grafana-native alerting for site probes | 2026-07-24 |
| [0002](0002-grafana-cloud-alloy-terraform-over-self-hosted.md) | Grafana Cloud + Alloy + Terraform over the self-hosted stack | 2026-05-12 |
| [0003](0003-host-local-push-over-central-pull.md) | Host-local push standardized over central pull | 2026-06-10 |
| [0004](0004-apply-on-merge-repo-is-durable-home.md) | Apply-on-merge; the repo is the only durable home for dashboard state | 2026-06-19 |
| [0005](0005-series-budget-engineering.md) | Series-budget engineering under the free-tier active-series cap | 2026-06-10 |
| [0006](0006-privacy-shaped-egress.md) | Privacy-shaped egress — LAN topology out of GitHub, transcripts scrubbed | 2026-06-17 |
| [0007](0007-flat-lentago-folder-frozen-uids.md) | One flat `Lentago` folder + frozen dashboard UIDs | 2026-07-25 |
