# ADR-0007: One flat `Lentago` folder + frozen dashboard UIDs

**Status:** Accepted (2026-07-25; reconstructed 2026-08-13)

## Context

As the dashboard set grew past a dozen, the question was how to organize it in
Grafana. A short-lived experiment (the 2026-07-18 product-line reorg, issue #162
→ PR #163, merged 2026-07-19) split the dashboards into four per-product folders
— `Lentago Lab`, `Claytonia`, `Solidago`, `Sites`. Six days of living with it
showed the folder tree cost a click on every navigation and expressed nothing a
title prefix couldn't. Two Grafana facts also bear on any reorg:

- **Destroying a Grafana folder takes its dashboards with it.** A folder uid
  change is a destroy/create, so recreating a folder to rename it is not free.
- **Dashboard UIDs are load-bearing.** Cross-dashboard `/d/` links, the
  office-display public share, and Terraform import blocks all reference UIDs by
  value; changing one is a destroy/create of the dashboard.

## Decision

**Collapse the taxonomy into a single flat `Lentago` folder and move the
grouping signal into the dashboard title** (PR #177, "Flatten the dashboard
folder taxonomy into a single Lentago folder", merged 2026-07-25), superseding
the six-day-old per-product folders (#162/#163). Every dashboard now carries a
`<Group> — <What>` title (`Claytonia — …`, `Solidago — …`, `Lentago Lab — …`,
`Sites — <domain>`), so the flat alphabetical list still clusters into the same
groups the folders used to draw. A new dashboard **must** take a group prefix;
without one the flat list has no structure at all.

Two identity-preservation rules make the move non-destructive:

- **The folder uid is reused, not recreated.** The single `grafana_folder`
  resource keeps the wizard-imported uid `afh7m8li40zk0d` via a Terraform
  `moved` block rather than taking a clean `lentago` uid — because a uid change
  would destroy the folder and its dashboards with it. Retitling in place is
  free, so the opaque uid stays (`terraform/folders.tf`).
- **Dashboard UIDs are frozen legacy names.** They are never changed to match
  the new titles: `firewalla-<name>` for the lab set, `claude-runner-fleet` for
  the fleet dashboard, `site-<domain-with-dashes>` and `<product>-<name>` for
  newer ones. UIDs are load-bearing, so titles carry the reorg and UIDs stay put.

One accepted one-time cost: a Grafana rule group's identity is
`<folder_uid>:<name>`, so moving the site-probe rule group out of the old
`Sites` folder **replaced** the group and reset its in-flight alert state once
(noted inline in `alerts.tf` and in ADR-0001's addendum).

## Alternatives

- **Per-product folders (the 2026-07-18 reorg).** *Recorded, superseded after
  six days.* It drew visible group boundaries but added a navigation click and
  duplicated information a title prefix already conveys — and every future
  cross-folder move risks the folder-destroy hazard. Worse for the cost it
  imposed relative to what it expressed.
- **Flat `Lentago` folder + title-prefix grouping.** *Recorded, chosen.* One
  folder, grouping in the title, uid reused via `moved`, dashboard UIDs frozen.
  The cost is that structure now depends on discipline (the mandatory group
  prefix) rather than being enforced by folder walls.
- **Recreate the folder with a clean `lentago` uid for a tidy import.**
  *Retrospective — not considered at the time.* Worse. A cosmetically nicer uid
  is not worth destroying the folder and every dashboard in it; the `moved`
  block delivers the single-folder outcome with zero destroy. Rejected on the
  same load-bearing-identity logic that freezes the dashboard UIDs.
- **Grafana tag-based organization instead of folders or title prefixes.**
  *Retrospective — not considered at the time.* Lateral-to-worse. Tags are a
  real grouping mechanism, but they're a secondary, filter-only affordance — the
  flat dashboard list still shows no structure without opening a tag filter,
  whereas a title prefix clusters the default alphabetical list for free. It
  would add a metadata surface to maintain for weaker default legibility.

## Consequences

- All drosera-owned dashboards live in the one `Lentago` folder
  (uid `afh7m8li40zk0d`), and a missing group prefix is now a structural defect,
  not a style nit.
- The folder uid and every dashboard uid are frozen; renaming any of them is a
  destroy/create, so titles — not UIDs — absorb all future renames.
- The alerting rule groups live in the same folder; ADR-0001's Decision section
  named the now-gone `Sites` folder and carries an addendum recording the move.
- The `moved`-block pattern is the standing tool for any future folder-level
  reshaping: change the resource, preserve the uid, never destroy.
