# ADR-0006: Privacy-shaped egress — LAN topology never in GitHub, transcripts ship scrubbed

**Status:** Accepted (2026-06-17 onward; reconstructed 2026-08-13)

## Context

This is a public repo, and the observability pipeline handles two kinds of data
that must not leak: the LAN's device-name↔IP topology, and the fleet's live
agent-reasoning stream. Both need to reach Grafana Cloud to be useful (a
dashboard can't resolve a raw IP to a device name, or show what a runner is
thinking, without the data being *somewhere* Grafana can query). The design
question is which channel each may travel and, for the reasoning stream, what
may be in it at all.

Two facts constrain the topology case specifically (issue #113):

- **Grafana Cloud executes datasource queries server-side, in the cloud.** It
  cannot reach `*.lan` or anything LAN-only, so a query-time lookup against a
  LAN service is impossible — the mapping has to already be inside Cloud.
- **LAN topology must not be published to public GitHub.** So the mapping cannot
  live in a checked-in file or a dashboard's JSON.

## Decision

**Shape egress by channel and by content, so private data reaches Cloud only
through trusted paths and only in scrubbed form.**

- **The name↔IP inventory travels the trusted Alloy → Cloud-Loki channel, never
  GitHub.** The device-inventory publisher pushes one log line per (device, IP)
  pair into Grafana Cloud Loki (`log_source="device_inventory"`) via the local
  Alloy; dashboards resolve IPs by joining that stream in Grafana
  *transformations* at render time (issue #113 → PR #122, merged 2026-07-03).
  The mapping ends up in the same trust domain as the Zeek logs that already
  carry every IP — Cloud — and never in the repo. (That this is also a
  zero-series representation is the series-budget angle, ADR-0005; here the
  driver is privacy.)
- **The fleet reasoning stream carries assistant text and tool names only.** The
  live agent-reasoning viewport (issue #71 → PR #77, merged 2026-06-17) ships a
  scrubbed transcript stream (`job="claude_transcript"`) to Cloud Loki: text and
  tool names, and deliberately **no** `thinking` blocks, **no** tool inputs, and
  **no** `user`/tool-result lines. The scrubbing is at the egress point, so the
  private material never leaves the worker rather than being filtered after the
  fact.

## Alternatives

- **Query-time LAN lookup (resolve IP→name by querying a LAN service at render
  time).** *Recorded, rejected — non-viable.* Grafana Cloud runs queries
  server-side and cannot reach the LAN (issue #113), so this cannot work at all;
  it is why the inventory must be pushed into Cloud ahead of time rather than
  looked up on demand.
- **Commit the name↔IP mapping to the repo (or embed it in dashboard JSON).**
  *Recorded, rejected.* Simplest to implement, but it publishes LAN topology to
  a public repo — the exact disclosure the policy forbids. The Loki channel
  keeps the mapping in-Cloud instead.
- **Ship the full reasoning transcript (thinking, tool inputs, user lines) for
  richer debugging.** *Recorded, rejected.* More useful for forensics but leaks
  prompt content, tool arguments, and user text off the worker — unacceptable
  egress. Text + tool names is the deliberately narrow slice that shows fleet
  activity without exfiltrating the sensitive body.
- **Encrypt the sensitive fields and ship them anyway (egress-then-decrypt).**
  *Retrospective — not considered at the time.* Worse. It would let the private
  material travel in exchange for key-management complexity and a standing
  "who can decrypt" question, and it still puts the ciphertext of LAN topology
  and reasoning into a public-adjacent SaaS. Scrubbing at source removes the
  data entirely, which is a smaller and more honest trust boundary than
  encrypting data you resolved not to expose.

## Consequences

- The device-inventory feed is a load-bearing dependency, not incidental: it is
  the *only* sanctioned route for name↔IP data into Cloud. If it stalls,
  dashboards fall back to raw IPs — an ingest-absence alert covers it
  (`terraform/alerts.tf`).
- The reasoning stream's value is deliberately capped at "what/which tool," not
  "why/with what." Anyone extending it must preserve the scrub — adding
  `thinking`, tool inputs, or user lines re-opens the egress this ADR closed.
- The transcript shipper is per-worker and **not** gitops-managed (unlike the
  central Alloy), so a scrub change is only real once redeployed on each worker,
  not on merge to `main`.
- Privacy and the series budget (ADR-0005) point the same way for the inventory
  feed: log stream, in-Cloud, zero series, out of GitHub.
