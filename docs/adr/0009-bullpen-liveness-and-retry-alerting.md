# ADR-0009: Bullpen liveness + retry alerting

**Status:** Accepted (2026-08-17)

## Context

Game-day #1 (2026-08-17, register: lentago/.github
`fleet-reports/incidents/2026-08-17-gameday-1-runner-kill.md`) killed a
claytonia worker (`pct stop` on LXC 117, claude-runner-5) 94 seconds into a
real job, on a pre-registered hypothesis. The queue's stale-heartbeat reaper
requeued the orphan as `.retry` and a second worker finished it in **84
seconds** — fully autonomous recovery — and the fourth prediction held too:
**no alert fired anywhere**, because nothing watches worker liveness or requeue
events. Grepping the archive then surfaced **two more real production reaps**
(2026-07-08), also unnoticed.

The dashboard (Claytonia — Runner Fleet) *renders* the liveness drop for anyone
watching, but an unwatched dashboard was the entire detection surface. This is
the third "absence of expected signal" member in the family with #176 (Loki
ingest absence) and #204 (red main-branch runs): silent self-healing hides real
infrastructure problems — a host that reboots its workers nightly would look
like nothing at all.

Issue #207 scopes the gap. **Boundary:** the alert rules belong in drosera
(it owns the observability pane); claytonia owns emitting any telemetry the
rules need that Loki does not yet carry.

## Decision

Add a fifth `grafana_rule_group` — **Bullpen liveness** — to
`terraform/alerts.tf`, three rules, all Loki-sourced and evaluated in Grafana's
engine (zero new Mimir series; the 15k free-tier cap is respected). All three
reuse the stack's single email contact point with per-rule routing, exactly
like the four groups before it.

### The signal: the fleet dashboard's own `job_running` heartbeat

The Claytonia — Runner Fleet dashboard's "Offload — concurrent runs" panel
counts distinct workers from `event="job_running"` on `{job="claude_runner"}`,
a heartbeat pushed ~every 15s **while a worker is processing a job**. The rules
build the headcount on the identical inner expression, aggregated to a scalar:

```logql
count(max by (worker) (count_over_time({job="claude_runner"} | json | event="job_running" [15m]) > bool 0))
```

1. **Workers below full strength (ticket, `warning`).** Headcount `< 5` for
   5m. A fully-dark fleet returns an empty result (NoData) and is escalated by
   rule 3, so this rule's `no_data_state = "OK"` — it covers only the 1–4
   partial-loss case and does not double-fire with the page.
2. **A `.retry` requeue occurred (ticket, `warning`).** Presence of any
   `runid =~ /.+\.retry/` line in the last hour, `for = "0s"` (fire
   immediately), `no_data_state = "OK"` (no retries is normal). The sharpest of
   the three — no busy-vs-alive caveat.
3. **Fleet fully dark (page, `critical`).** Headcount `== 0` for 10m — the
   betula#86 "queue fully dark" shape applied to the bullpen. Zero workers is
   an *empty* Loki result, so `no_data_state = "Alerting"` is the crux (same
   stance as the ingest-absence group), with `lt 1` on the threshold as the
   belt to that suspenders.

### Why these thresholds / windows

- **15m headcount window.** job_running fires ~every 15s while busy, so 15m is
  generous coverage for a worker briefly between jobs — long enough that a
  healthy busy fleet accumulates all five, short enough that a dead worker
  drops out within window + `for`.
- **Page `for` (10m) > ticket `for` (5m).** A page must survive a brief lull; a
  ticket can be more eager.
- **Retry window 1h, `for = "0s"`.** A requeue is a discrete event, not a
  trend; the 1h window ensures a single reap is caught and the alert clears on
  its own (repeat_interval 6h > window, so exactly one ticket per reap).

## Consequences / known limitation

**`job_running` marks BUSY workers, not idle-but-alive ones** — the panel
description says "distinct busy workers" verbatim. There is no always-on
runner-fleet liveness heartbeat in Loki today: `session_running` is the
workstation (`claude_local`) heartbeat, and the queue's own
`workers/<host>.alive` 30s heartbeat is a git-queue **file**, never shipped to
Loki. So on a genuinely low-load or idle stretch, fewer than 5 (or zero)
workers will have run a job in the window and the two headcount rules **will
fire even though every worker is healthy**.

We accept that trade-off to close the game-day gap now (this repo's standing
posture is *prefer noise over silence* for absence alerts). The **durable fix
is claytonia shipping `workers/<host>.alive` to Loki as an always-on
heartbeat** — the boundary above — at which point rules 1/3 flip their selector
to that stream and the busy/alive ambiguity disappears. The retry rule (2) has
no such caveat and stands on its own regardless.

**Two assumptions the reviewer must live-verify** (the authoring env had no
Loki credentials, so the queries are unproven against live data):

1. `worker` is a JSON field on `job_running` events (the dashboard aggregates
   `by (worker)` on this stream, which implies it is).
2. A requeued run's `.retry` marker appears in Loki as a `runid` matching
   `/.+\.retry/`. If claytonia carries retry state in a different field (an
   `attempt` count, a `retry=true` flag), swap rule 2's selector — the rule
   shape is unchanged.

## Alternatives considered

- **Wait for the always-on heartbeat before shipping any rule.** Rejected: the
  gap is real *today* and the retry rule needs nothing new. Shipping now with a
  documented caveat beats leaving the fleet un-alerted for a claytonia change.
- **Add a Mimir gauge for worker count.** Rejected: new active series against
  the 15k cap, for a signal Loki already carries.
- **Page on `< 5` instead of `== 0`.** Rejected: too noisy given the busy-only
  signal; `< 5` tickets, `== 0` pages, keeping the page for genuine darkness.
