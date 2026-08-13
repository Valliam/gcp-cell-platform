# 0008 — Cross-region promotion is a human decision

**Status:** accepted

## Context

Each prod cell has two layers of database redundancy:

- `availability_type = REGIONAL` — a synchronous standby in a second zone of the
  primary region, with automatic failover and RPO 0.
- A cross-region read replica in the standby region, asynchronous, RPO bounded
  by replica lag.

Cloud SQL can be configured to treat the cross-region replica as a failover
target. It is tempting: it would automate the remaining manual step.

## Decision

Automatic failover **within** the region (Cloud SQL manages it, nobody is
paged). Promotion **across** regions is manual, performed against
[`docs/runbooks/failover.md`](../runbooks/failover.md).

`replica_configuration.failover_target = false`.

## Consequences

Why manual:

- **Split brain.** Automatic cross-region promotion triggers on the primary
  being unreachable. A network partition looks identical to a region loss from
  the standby's perspective. Promote on a partition and there are two writers,
  and reconciling divergent PostgreSQL instances after the fact is worse than
  any outage the automation would have shortened.
- **Promotion is one-way.** It breaks the replication relationship. Rebuilding
  it means a fresh replica seeded from the new primary, which for a real dataset
  is hours. That is not a decision to make on a health check's behalf.
- **Regional loss is rare and long.** The events this protects against last long
  enough that ten minutes of human judgement is a small fraction of the RTO, and
  the RTO target of 30 minutes has room for it.
- **The common failures are already automated.** Zone loss, instance failure and
  maintenance are covered by the in-region synchronous standby, with no human
  involved. What is left for a human is precisely the ambiguous case.

What makes the manual path fast enough to hit a 30-minute RTO:

- The replica already exists, is sized to serve, and has a working CMEK key in
  its own region — all three verified read-only by `scripts/dr_drill.sh`,
  which is safe to run against production.
- The alert fires at half the RPO, so the on-call is looking at the situation
  before the objective is at risk.
- The runbook's decision tree distinguishes "primary unreachable from one place"
  from "region is gone", which is the judgement the automation cannot make.

## Related gap

Cross-region replication does not protect against a bad migration — the replica
faithfully reproduces the damage. Point-in-time recovery is the control for that
failure mode, it is enabled on every prod cell, and the drill checks it. The two
mechanisms answer different questions and neither substitutes for the other.
