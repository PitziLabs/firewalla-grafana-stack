# ADR-0003: Host-local push standardized over central pull

**Status:** Accepted (2026-06-10; reconstructed 2026-08-13)

## Context

There are two ways `node_exporter` metrics can reach Mimir:

- **Central pull** — the LXC 105 Alloy scrapes each host's `:9100` as a target
  in a `prometheus.scrape "node"` block.
- **Host-local push** — each host runs its own Alloy that scrapes
  `localhost:9100` and `remote_write`s to Cloud directly.

Both models publish identical labels (`job="node"`, `instance="<host>"`), so a
dashboard cannot tell which one produced a given series. Central pull keeps
collection in one place but couples every host's metrics to the health and
reachability of the LXC, and it grows a hand-maintained target list that has to
track hosts as they come and go.

## Decision

Standardize on **host-local push** (PR #50, "Add deploy-alloy.sh: host-local
Alloy push agent", merged 2026-06-10). Each host runs its own Alloy scraping
`localhost:9100` and remote-writing at 15s; `scripts/deploy-alloy.sh <instance>`
installs it, with secrets in a `0600 /etc/default/alloy` that is never
committed. Because both models emit identical labels, the migration is
invisible to every dashboard — the whole point of holding the label scheme
constant.

Two rules make the standardization safe:

- **Never both for one host.** Running central pull *and* host-local push for
  the same host double-counts its series against the free-tier cap (ADR-0005).
  Moving a host to push therefore **requires** deleting it from the central
  `prometheus.scrape "node"` block. PR #54 ("Drop central node_exporter scrape —
  all hosts now push", merged 2026-06-10, same day) did exactly that once the
  push agents were in place.
- **HAOS is the documented exception.** Home Assistant OS is a locked
  appliance with no room for a system Alloy, so it stays on the central Alloy's
  Home Assistant `/api/prometheus` scrape. The exception is written down rather
  than left as a silent gap.

## Alternatives

- **Central pull only (status quo).** *Recorded, superseded.* Simple to reason
  about but couples all node metrics to the LXC's liveness and needs a
  hand-maintained target list. Kept only for HAOS, where a host-local agent is
  impossible.
- **Host-local push, standardized.** *Recorded, chosen.* Decouples each host's
  metrics from the LXC and scales without editing a central target list. The
  cost is an agent per host and the never-both discipline to avoid
  double-counting.
- **Prometheus agent mode / vmagent instead of Alloy on each host.**
  *Retrospective — not considered at the time.* Lateral. The mechanics are
  equivalent — a lightweight per-host scraper that remote-writes — and it would
  produce the same identical-label series. It buys nothing here and costs a
  second agent binary and config dialect to learn and deploy alongside the Alloy
  the fleet already standardizes on, so it is strictly more surface for no
  behavioural gain.

## Consequences

- Each host owns an Alloy agent; `deploy-alloy.sh` is the one install path and
  `/etc/default/alloy` (0600, uncommitted) is where per-host secrets live.
- The never-both rule is load-bearing for the series budget: violating it
  silently doubles a host's series (ADR-0005). Any host migration is a two-step
  edit — add the push agent, then remove the central scrape target.
- Dashboards stay model-agnostic forever, as long as the identical-label
  invariant holds. Changing `job`/`instance` labelling on one path but not the
  other would break that guarantee.
- HAOS remains on central pull by design; a future non-appliance replacement
  would be a candidate to move onto push and out of the central block.
